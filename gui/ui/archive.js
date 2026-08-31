// pm-ui「归档」页（P8-D，DESIGN-P8 §23.2）：三张卡——暂存区归档 / 成片 → 相册 /
// 非 jpg 转换。外链脚本、无内联；由 app.js 用共享工具构造：
//   window.pmArchive({ $, el, mib, get, getJson, post, stamp, stale, bodyLines, shrink, loadPlans })
//     → { loadArchive, busy }
// 端点：/api/status（暂存摘要，只读）、/api/album/candidates（只读）、
// /api/import/plan、/api/album/add-plan、/api/convert/plan（都只生成计划文件——转换的
// 第一段会写主库 .pm/derived 的派生件，那是 pm 自建状态，原文件不动）。执行仍在
// 「计划」页 / 终端 pm apply。页面永不直接碰照片，一切经 pm serve。
window.pmArchive = function (u) {
  const { $, el, mib, get, getJson, post, stamp, stale, bodyLines, shrink, loadPlans } = u;
  let thumbUrls = [];
  let busyFlag = false;
  const picked = new Set(); // 成片 → 相册：勾选的 <事件夹>/<文件名>（候选给的 rel，原样回传）
  const convPicked = new Set(); // 转换：勾选的库内相对路径（候选给的 path，原样回传）
  function note(kind, text) { const b = $("#archive-result"); b.className = "banner " + kind; b.textContent = text; }
  function updateButtons() {
    $("#album-progress").textContent = `已选 ${picked.size}`;
    $("#btn-album-add").disabled = busyFlag || picked.size === 0;
    $("#btn-convert").disabled = busyFlag || convPicked.size === 0;
    $("#btn-import-plan").disabled = busyFlag;
  }
  async function loadArchive() {
    // 同分类推送页：代号作废旧轮（连按数字键 3 / 快速切页时旧响应晚到）
    const gen = stamp("archive");
    try {
      const s = await getJson("/api/status");
      if (stale("archive", gen)) return;
      const i = s.index, st = $("#archive-staging");
      if (!i) st.textContent = "主库尚未索引——先在终端 pm scan。";
      else if (!i.stagingEvents.length) st.textContent = "暂存区没有待归档的事件夹。";
      else st.textContent = `暂存区 ${i.stagingEvents.length} 个事件夹 · ${i.stagingFiles} 文件（其中 ${i.stagingArchived} 已在归档层有同内容副本）：` + i.stagingEvents.slice(0, 12).join("、") + (i.stagingEvents.length > 12 ? " …" : "");
      const grid = $("#album-grid"); grid.innerHTML = "";
      for (const x of thumbUrls) URL.revokeObjectURL(x); thumbUrls = [];
      picked.clear(); convPicked.clear();
      let c;
      try { c = await getJson("/api/album/candidates"); } catch (e) {
        if (stale("archive", gen)) return;
        grid.appendChild(el("div", "muted", "候选读不出来：" + e.message)); renderConvert([]); updateButtons(); return;
      }
      if (stale("archive", gen)) return;
      const total = c.events.reduce((n, ev) => n + ev.photos.length, 0);
      const nIg = (c.ignored || []).length;
      $("#album-cand-meta").textContent = (total ? `${total} 张成片 jpg 还没进相册（${c.events.length} 个事件夹）` : "成片里的 jpg 都已在相册里") + (nIg ? ` · 已忽略 ${nIg} 张` : "");
      const cards = [];
      for (const ev of c.events) {
        const h = el("div", "grid-head");
        h.appendChild(el("b", null, ev.event));
        const all = el("button", "btn ghost", "全选这个事件夹");
        all.onclick = () => {
          if (busyFlag) return;
          for (const p of ev.photos) picked.add(p.rel);
          for (const x of grid.querySelectorAll(".gcard")) if (x.dataset.event === ev.event) x.classList.add("done");
          updateButtons();
        };
        h.appendChild(all); grid.appendChild(h);
        for (const p of ev.photos) {
          const card = el("div", "gcard"); card.dataset.event = ev.event;
          const ph = el("div", "ph", "加载中…"); card.appendChild(ph);
          const body = el("div", "body");
          body.appendChild(el("div", "name", p.name));
          body.appendChild(el("div", "meta", (p.size != null ? mib(p.size) : "") + (p.conflict ? " · ⚠ 相册已有同名不同内容（进计划会待裁决）" : "")));
          // 忽略此候选（按内容 sha，主库 .pm 本地决定）：stopPropagation——别把卡勾上
          const ig = el("button", "btn ghost mini", "忽略");
          ig.onclick = (ev) => { ev.stopPropagation(); ignoreCall({ ignore: [p.rel] }, `已忽略 ${p.name}`).catch((e) => note("bad", "请求失败：" + e.message)); };
          body.appendChild(ig);
          card.appendChild(body);
          card.onclick = () => {
            if (busyFlag) return;
            if (picked.has(p.rel)) picked.delete(p.rel); else picked.add(p.rel);
            card.classList.toggle("done", picked.has(p.rel)); updateButtons();
          };
          grid.appendChild(card); cards.push([p, ph]);
        }
      }
      if (!total) grid.appendChild(el("div", "muted", "没有候选：成片里的 jpg 都已在相册（或主库还没有成片）。"));
      renderIgnored(c.ignored || [], c.ignoreStale || []);
      renderConvert(c.nonJpg);
      // 索引里损坏跳过的快照行：与 CLI 一样说出来，不吞——写在专用行，不占结果横幅
      // （门禁 F3：占横幅会在 planCall 收尾的 loadArchive 里把刚出的计划 id 抹掉）
      $("#archive-warnings").textContent = (c.warnings || []).length ? "⚠ 索引快照损坏已跳过（候选可能不全，先在终端 pm scan）：" + c.warnings.join("；") : "";
      updateButtons();
      for (const [p, ph] of cards) {
        if (stale("archive", gen)) return;
        try {
          const blob = await (await get("/api/thumb/" + p.sha)).blob();
          const small = await shrink(blob);
          if (stale("archive", gen)) return;
          if (!small) { ph.textContent = "缩略失败（不挂原图）"; continue; }
          const url = URL.createObjectURL(small); thumbUrls.push(url);
          const img = document.createElement("img"); img.alt = p.name; img.src = url;
          ph.textContent = ""; ph.appendChild(img);
        } catch (err) { ph.textContent = "无缩略图：" + err.message; }
      }
    } catch (e) {
      if (stale("archive", gen)) return; // stale 失败不许改画面（41 轮 #2）
      throw e;
    }
  }
  // 已忽略的候选（折叠区）：逐条可取消（按 sha）；失效记录（对象已不在候选——
  // 已进相册/已删/换了内容）只提示，一键清掉的决定权在用户。
  function renderIgnored(list, staleList) {
    const box = $("#album-ignored"), ul = $("#album-ignored-list");
    ul.innerHTML = "";
    box.classList.toggle("hidden", !list.length && !staleList.length);
    $("#album-ignored-sum").textContent = `已忽略 ${list.length} 张` + (staleList.length ? `（另有 ${staleList.length} 条记录已失效）` : "") + " —— 点开取消";
    for (const x of list) {
      const li = el("li");
      li.appendChild(el("span", "mono small", x.path + (x.size != null ? "（" + mib(x.size) + "）" : "")));
      const un = el("button", "btn ghost mini", "取消忽略");
      un.onclick = () => ignoreCall({ unignore: [x.sha] }, `已恢复候选 ${x.name}`).catch((e) => note("bad", "请求失败：" + e.message));
      li.appendChild(un); ul.appendChild(li);
    }
    for (const x of staleList) {
      const li = el("li");
      li.appendChild(el("span", "muted small", "已失效：" + x.path + "（对象已不在候选）"));
      const un = el("button", "btn ghost mini", "清掉这条");
      un.onclick = () => ignoreCall({ unignore: [x.sha] }, "已清掉失效记录").catch((e) => note("bad", "请求失败：" + e.message));
      li.appendChild(un); ul.appendChild(li);
    }
  }
  // 忽略/取消的共用 POST（写主库 .pm/album-ignore.json，照片零改动）：成功后整页重载
  async function ignoreCall(payload, okMsg) {
    if (busyFlag) return;
    busyFlag = true; updateButtons();
    try {
      const r = await post("/api/album/ignore", payload);
      const body = await r.json().catch(() => ({}));
      if (!r.ok) note("bad", "忽略清单没写入：" + (body.error || ("HTTP " + r.status)) + bodyLines(body));
      else note("ok", okMsg + "——只是主库 .pm 里的本地决定，随时可改。");
    } finally { busyFlag = false; updateButtons(); }
    try { await loadArchive(); } catch (e) { $("#archive-result").textContent += "\n（页面刷新失败：" + e.message + "，按 3 重进本页）"; }
  }
  function renderConvert(list) {
    const ul = $("#convert-list"); ul.innerHTML = "";
    $("#convert-meta").textContent = list.length ? `${list.length} 个非 jpg 照片（相册只收 jpg；RAW 不在此列）` : "成片 / 相册下没有非 jpg 照片";
    for (const x of list) {
      const li = el("li"), lab = el("label"), cb = document.createElement("input");
      cb.type = "checkbox";
      cb.onchange = () => { if (cb.checked) convPicked.add(x.path); else convPicked.delete(x.path); updateButtons(); };
      lab.appendChild(cb);
      lab.appendChild(el("span", "mono small", " " + x.path + (x.size != null ? "（" + mib(x.size) + "）" : "")));
      li.appendChild(lab); ul.appendChild(li);
    }
  }
  // 三个「生成计划」按钮共用：POST → {code, planId, log}。无 planId 时把 log 摆出来
  // （「详情见终端」在 GUI 下是句空话：serve 的 stdout 挂在空设备上）。
  async function planCall(path, payload, what) {
    busyFlag = true; updateButtons();
    try {
      const r = await post(path, payload);
      const body = await r.json().catch(() => ({}));
      if (!r.ok) { note("bad", what + "失败：" + (body.error || ("HTTP " + r.status)) + bodyLines(body)); return; }
      const log = (body.log || []).join("\n");
      if (body.planId) note("ok", `${what}：计划已生成 ${body.planId}——只写了计划文件，照片未动。\n下一步到「计划」页查看明细并执行（或在终端 pm apply ${body.planId}）` + (log ? "\n" + log : ""));
      else note(body.code === 0 ? "ok" : "warn", (body.code === 0 ? what + "：无需计划（全部已落位）。" : what + "：没有生成计划——看下面的交代。") + "\n" + (log || `退出码 ${body.code}`));
      await loadPlans().catch(() => {});
    } catch (e) { note("bad", "请求失败：" + e.message); }
    finally { busyFlag = false; updateButtons(); }
    // 刷新失败不改判：计划已经生成，把它作为附注接在文案后面
    try { await loadArchive(); } catch (e) { $("#archive-result").textContent += "\n（页面刷新失败：" + e.message + "，按 3 重进本页）"; }
  }
  $("#btn-import-plan").onclick = () => planCall("/api/import/plan", { alsoAlbum: $("#import-also-album").checked }, "暂存区归档");
  $("#btn-album-add").onclick = () => planCall("/api/album/add-plan", { paths: [...picked] }, "成片 → 相册");
  $("#btn-convert").onclick = () => planCall("/api/convert/plan", { paths: [...convPicked], alsoAlbum: $("#convert-also-album").checked }, "转换");
  $("#btn-archive-reload").onclick = () => loadArchive().catch((e) => note("bad", "读取失败：" + e.message));
  return { loadArchive, busy: () => busyFlag };
};
