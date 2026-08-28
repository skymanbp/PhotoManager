// pm-ui「分类推送」页（P8-A 自 app.js 拆出；P8-D 加照片记录三格与 AI 建议入口）。
// 外链脚本、无内联；由 app.js 用共享工具构造：
//   window.pmVault({ $, el, mib, get, getJson, post, stamp, stale, bodyLines })
//     → { loadVault, makePlan, suggest, shrink, busy }
// 端点：/api/vault/new（只读）、/api/vault/notes（GET 回显 / POST 写改过的记录）、
// /api/vault/hold（记「暂不同步」决定）、/api/vault/push-plan（只生成计划文件）、
// /api/suggest（只读级：拉起你自己账号下的 claude -p 看图，只出建议）。
// 页面永不直接碰照片，一切经 pm serve。
window.pmVault = function (u) {
  const { $, el, mib, get, getJson, post, stamp, stale, bodyLines } = u;
  let thumbUrls = [];
  let vaultDrift = 0; // 没有 NEW 但有 DRIFT 时，也能出纯裁决计划
  let heldInitial = new Set(); // 打开这一页时盘上已有的「暂不同步」决定
  let submitting = false;      // 提交期间冻结选择：两步必须看同一份快照
  let suggesting = false;      // AI 建议进行中：不提交、不再发第二次
  const HOLD = "__hold__";     // 第四个按钮的哨兵值——它不是 vault 类目
  const assign = new Map(); // name -> category | HOLD
  // P8-D 照片记录（DESIGN-P8 §21，用户裁定 R6 (b)）：每张卡三格（地点 / 坐标 / 标题），
  // 打开页时从 GET /api/vault/notes 回显；AI 建议只**预填**（不标已定）；用户一敲键
  // source 就成 user；提交时只把「改了的」发给 POST /api/vault/notes（差集，同 holdOps）。
  const notes = new Map(); // name -> { inputs: {location, coordinates, title}, initial: {…}|null, source, basis }
  const NOTE_KEYS = ["location", "coordinates", "title"];
  async function shrink(blob) {
    // 原图动辄 10–75 MB：交给解码器按目标尺寸缩放，再转成小 JPEG，避免 15 张全分辨率位图撞爆 WebView。
    // 失败返回 null（挂占位符）：回退到原图 = 把已修掉的那条内存路径重新引回来（codex 二十轮 minor）。
    let bmp = null;
    try {
      bmp = await createImageBitmap(blob, { resizeWidth: 640, resizeQuality: "medium" });
      const cv = document.createElement("canvas"); cv.width = bmp.width; cv.height = bmp.height;
      cv.getContext("2d").drawImage(bmp, 0, 0);
      return await new Promise((res) => cv.toBlob((b) => res(b), "image/jpeg", 0.85));
    } catch { return null; } finally { if (bmp) bmp.close(); }
  }
  // 与盘上已有决定的差集：只把「改了的」发给服务端。
  function holdOps() {
    const now = new Set([...assign.entries()].filter(([, c]) => c === HOLD).map(([n]) => n));
    return {
      hold: [...now].filter((n) => !heldInitial.has(n)),
      unhold: [...heldInitial].filter((n) => !now.has(n)),
      count: now.size,
    };
  }
  // 记录的当前值 = 三格 + 已选类目。「暂不同步」不是类目：按下它时沿用盘上记录里的
  // 类目（有就留着）——暂不同步是「先不推」，不是「把上次确认过的记录抹掉」。
  function noteNow(name) {
    const n = notes.get(name), cat = assign.get(name);
    const o = { category: cat && cat !== HOLD ? cat : (n.initial ? n.initial.category : null) };
    for (const k of NOTE_KEYS) o[k] = n.inputs[k].value.trim() || null;
    return o;
  }
  const noteKey = (o) => JSON.stringify([o.category, o.location, o.coordinates, o.title]);
  const emptyNote = { category: null, location: null, coordinates: null, title: null };
  // 与盘上回显的差集：改了且至少一格非空 → set；盘上有、现在全空 → clear。
  function noteOps() {
    const set = [], clear = [];
    for (const [name, n] of notes) {
      const now = noteNow(name);
      if (noteKey(now) === noteKey(n.initial || emptyNote)) continue;
      if (noteKey(now) === noteKey(emptyNote)) { if (n.initial) clear.push(name); continue; }
      set.push(Object.assign({ name, source: n.source || "user" }, now));
    }
    return { set, clear };
  }
  function updateProgress(total) {
    const ops = holdOps();
    const cats = [...assign.values()].filter((c) => c !== HOLD).length;
    const nops = noteOps();
    $("#assign-progress").textContent = `已定 ${assign.size} / ${total}（分类 ${cats} · 暂不同步 ${ops.count}）` + (nops.set.length || nops.clear.length ? ` · 记录改动 ${nops.set.length + nops.clear.length}` : "") + (vaultDrift ? ` · ${vaultDrift} 项 DRIFT 待裁决` : "");
    // DRIFT-only 的 vault（没有 NEW）也要能出纯裁决计划，否则按钮永远灰着（二十轮 minor）。
    $("#btn-plan").disabled = cats === 0 && vaultDrift === 0 && !ops.hold.length && !ops.unhold.length && !nops.set.length && !nops.clear.length;
  }
  async function loadVault() {
    // single-flight：连按数字键会并发起多轮，旧轮在新轮 revoke 之后
    // 还会继续下载原图并建 blob URL（codex 二十轮 minor）。用代号作废旧轮。
    const gen = stamp("vault");
    try {
      const grid = $("#vault-grid"); grid.innerHTML = "";
      for (const u of thumbUrls) URL.revokeObjectURL(u); thumbUrls = [];
      // 这里**不**清 #plan-result：makePlan 成功后紧接着调 loadVault 刷新网格，
      // 顺手就把刚写出来的「计划 id / 执行命令 / 计划文件路径」抹了——那是这一页
      // 唯一一次说出计划 id 的机会。横幅只在用户**开始新一轮**时清（makePlan 开头）。
      assign.clear(); notes.clear(); vaultDrift = 0; heldInitial = new Set();
      let meta;
      try { meta = await getJson("/api/vault/new"); } catch (e) {
        if (stale("vault", gen)) return; // 旧轮失败：别动新一轮的网格
        grid.appendChild(el("div", "muted", "vault 未配置或不可用：" + e.message)); updateProgress(0); return;
      }
      if (stale("vault", gen)) return;
      // 照片记录回显：读不出不阻塞分类（横幅提示，三格按空处理）
      const noteMap = new Map();
      try { const nj = await getJson("/api/vault/notes"); for (const x of nj.notes || []) noteMap.set(x.name, x); }
      catch (e) { if (stale("vault", gen)) return; const b = $("#plan-result"); b.className = "banner warn"; b.textContent = "照片记录读不出来（三格按空处理）：" + e.message; }
      if (stale("vault", gen)) return;
      vaultDrift = (meta.drift || []).length;
      heldInitial = new Set((meta.held || []).map((e) => e.name));
      for (const n of heldInitial) assign.set(n, HOLD); // 回显盘上已有的决定
      const items = (meta.new || []).concat(meta.held || []);
      if (!items.length) {
        updateProgress(0);
        grid.appendChild(el("div", "muted", vaultDrift
          ? `没有待推送的 NEW；但有 ${vaultDrift} 项 DRIFT（同名、内容不同）——点「保存决定并生成推送计划」出一份纯裁决计划，再在终端 pm resolve。`
          : "没有待推送的 NEW 照片——相册与 vault 已一致。"));
        return;
      }
      const cards = [];
      for (const e of items) {
        const card = el("div", "gcard");
        const ph = el("div", "ph", "加载中…"); card.appendChild(ph);
        const body = el("div", "body"); body.appendChild(el("div", "name", e.name)); body.appendChild(el("div", "meta", e.size != null ? mib(e.size) : ""));
        const seg = el("div", "seg");
        // 盘上记录里已确认的类目也回显成已选（步 9 C9）：此前只回显三格不回显类目，
        // 一张没再碰的卡在 noteOps 里会被算成「类目改成了 null」而清掉记录。
        // 「暂不同步」优先：它是更晚、更明确的决定。
        const ini = noteMap.get(e.name);
        if (ini && ini.category && !assign.has(e.name)) assign.set(e.name, ini.category);
        // 三个 vault 类目 + 第四个「暂不同步」：后者不是 vault 目录，只是主库里
        // 的一条本地决定，随时能改回类目。
        for (const c of meta.categories.concat([HOLD])) {
          const b = el("button", c === HOLD ? "hold" : null, c === HOLD ? "暂不同步" : c);
          b.onclick = () => { if (submitting || suggesting) return; assign.set(e.name, c); for (const x of seg.children) x.classList.toggle("on", x === b); card.classList.add("done"); updateProgress(items.length); };
          if (assign.get(e.name) === c) { b.classList.add("on"); card.classList.add("done"); }
          seg.appendChild(b);
        }
        body.appendChild(seg);
        // 照片记录三格 + 依据行（AI 的 basis / 盘上记录的状态）
        const nt = el("div", "note"), inputs = {};
        for (const [k, phText] of [["location", "地点（如 Hallstatt）"], ["coordinates", "坐标 lat, lng"], ["title", "标题"]]) {
          const inp = document.createElement("input"); inp.type = "text"; inp.placeholder = phText; inp.spellcheck = false;
          inp.value = ini && ini[k] != null ? String(ini[k]) : "";
          inp.addEventListener("input", () => { if (submitting) return; const n = notes.get(e.name); n.source = "user"; n.basis.textContent = ""; card.classList.toggle("noted", NOTE_KEYS.some((kk) => n.inputs[kk].value.trim())); updateProgress(items.length); });
          inputs[k] = inp; nt.appendChild(inp);
        }
        const basis = el("div", "basis muted small", ini ? `记录：${ini.status}${ini.source ? " · 来源 " + ini.source : ""}` : "");
        nt.appendChild(basis); body.appendChild(nt);
        notes.set(e.name, { inputs, basis, source: ini ? ini.source : "user", initial: ini ? { category: ini.category || null, location: ini.location || null, coordinates: ini.coordinates || null, title: ini.title || null } : null });
        if (ini) card.classList.add("noted");
        card.appendChild(body); grid.appendChild(card);
        cards.push([e, ph]);
      }
      // 相册里的非 jpg（UNPUSHABLE）：只读展示，不进 notes / assign（步 9 C8）——
      // 它推不上 vault，勾一张会让整批 push-plan 400；转成 jpg 在「归档」页。
      for (const e of meta.unpushable || []) {
        const card = el("div", "gcard unpushable");
        card.appendChild(el("div", "ph", "非 jpg"));
        const body = el("div", "body"); body.appendChild(el("div", "name", e.name));
        body.appendChild(el("div", "meta", (e.size != null ? mib(e.size) + " · " : "") + "相册只收 jpg：推不上 vault。到「归档」页第三张卡转成 jpg 再来。"));
        card.appendChild(body); grid.appendChild(card);
      }
      updateProgress(items.length);
      // 顺序拉图（每张原图可能几十 MB），缩小后再挂上去
      for (const [e, ph] of cards) {
        if (stale("vault", gen)) return; // 已被新一轮取代：不再下载、不再建 URL
        try {
          if (!e.sha) throw new Error("catalog 无 sha");
          const blob = await (await get("/api/thumb/" + e.sha)).blob();
          const small = await shrink(blob);
          if (stale("vault", gen)) return;
          if (!small) { ph.textContent = "缩略失败（不挂原图）"; continue; }
          const url = URL.createObjectURL(small); thumbUrls.push(url);
          const img = document.createElement("img"); img.alt = e.name; img.src = url;
          ph.textContent = ""; ph.appendChild(img);
        } catch (err) { ph.textContent = "无缩略图：" + err.message; }
      }
    } catch (e) {
      if (stale("vault", gen)) return; // stale 失败不许改画面（41 轮 #2）
      throw e; // 当前代的失败照旧交给调用方兜底（fail 横幅等）
    }
  }
  // AI 建议（DESIGN-P8 §22）：至多 20 张未标「暂不同步」的卡；类目只在按钮上描边
  // （.ai ≠ .on，不代点），三格只填空着的；每次点击都是显式同意，花的是用户自己的账号。
  async function suggest() {
    if (submitting || suggesting) return; // 一次一个：提交中不发建议，建议中不提交（页面级与 serve 的 409 对齐）
    const out = $("#plan-result");
    const names = [...notes.keys()].filter((n) => assign.get(n) !== HOLD).slice(0, 20);
    if (!names.length) { out.className = "banner warn"; out.textContent = "没有可建议的照片（这一页没有 NEW，或都已标「暂不同步」）。"; return; }
    const btn = $("#btn-vault-ai"), label = btn.textContent;
    suggesting = true; $("#btn-plan").disabled = true;
    btn.disabled = true; btn.textContent = "AI 看图中…（claude -p，最长 3 分钟）";
    try {
      const r = await post("/api/suggest", { kind: "classify", names });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { out.className = "banner bad"; out.textContent = "AI 建议失败：" + (j.error || ("HTTP " + r.status)) + bodyLines(j) + (j.raw ? "\n模型原文：" + j.raw : ""); return; }
      let filled = 0;
      for (const it of j.items || []) {
        const n = notes.get(it.name); if (!n) continue;
        const card = n.inputs.location.closest(".gcard");
        for (const b of card.querySelectorAll(".seg button")) b.classList.toggle("ai", it.category != null && b.textContent === it.category);
        for (const k of NOTE_KEYS) if (it[k] && !n.inputs[k].value.trim()) { n.inputs[k].value = it[k]; filled++; }
        n.source = it.source || "none";
        n.basis.textContent = "AI：" + (it.basis || "（无依据说明）") + (it.category ? " · 建议类目 " + it.category : "") + " · 把握 " + n.source;
        card.classList.toggle("noted", NOTE_KEYS.some((kk) => n.inputs[kk].value.trim()));
      }
      updateProgress(notes.size);
      out.className = "banner ok";
      out.textContent = `AI 建议已到：${(j.items || []).length} 张有回答（预填 ${filled} 格；未回答 ${(j.dropped || []).length} 张）——只是预填：类目仍要你点，记录随「保存决定并生成推送计划」写入。` + (j.cost != null ? `\n本次约 $${Number(j.cost).toFixed(2)}（你的 Claude 账号）。` : "");
    } catch (e) { out.className = "banner bad"; out.textContent = "请求失败：" + e.message; }
    finally { suggesting = false; btn.disabled = false; btn.textContent = label; updateProgress(notes.size); }
  }
  async function makePlan() {
    if (submitting || suggesting) return;
    const btn = $("#btn-plan"); btn.disabled = true;
    const out = $("#plan-result");
    // 新一轮开始 = 上一轮的结论作废，只有这里清横幅（loadVault 不再碰它）。
    out.className = "banner hidden"; out.textContent = "";
    const lines = [];
    // 三步之间会 await：先把**全部**提交状态快照下来（选择 + DRIFT 数 + 记录差集），
    // 提交期间点击、切页、数字键都不再改它（submitting）。
    const snap = new Map(assign);
    const driftSnap = vaultDrift;
    const nops = noteOps();
    submitting = true;
    try {
      // 1) 先落「暂不同步」的增删：服务端拒收 held 文件的 push，撤销必须先生效
      const ops = holdOps();
      if (ops.hold.length || ops.unhold.length) {
        const rh = await post("/api/vault/hold", { hold: ops.hold, unhold: ops.unhold });
        // 体解析失败不能把 4xx 甩进 catch：那会把服务端逐行给出的**为什么**
        // 换成一句 "Unexpected token"，用户看不到哪一条决定不合法。
        const jh = await rh.json().catch(() => ({}));
        if (!rh.ok) { out.className = "banner bad"; out.textContent = "决定未保存：" + (jh.error || ("HTTP " + rh.status)) + bodyLines(jh); btn.disabled = false; return; }
        // 已落盘 → 立刻推进 baseline：第二步失败后重试不该再撤一次已撤的决定。
        // 只收**这一页有的**名字（步 9 C6）：响应里的 held 是整个文件，含别的
        // 页面 / 终端记下、本页根本没渲染的名字；照单全收会让重试把它们全 unhold。
        heldInitial = new Set((jh.held || []).filter((n) => notes.has(n)));
        lines.push(`已记下决定：暂不同步 +${ops.hold.length} / 恢复 ${ops.unhold.length}（名单共 ${jh.count} 条；只写主库 .pm，vault 与照片没动）`);
      }
      // 2) 照片记录的差集（只写主库 .pm/vault-notes.json；photos.json 不在 pm 写域）
      if (nops.set.length || nops.clear.length) {
        const rn = await post("/api/vault/notes", nops);
        const jn = await rn.json().catch(() => ({}));
        if (!rn.ok) { out.className = "banner bad"; out.textContent = (lines.join("\n") + "\n照片记录未保存：" + (jn.error || ("HTTP " + rn.status)) + bodyLines(jn)).trim(); btn.disabled = false; return; }
        for (const s of nops.set) { const n = notes.get(s.name); if (n) n.initial = { category: s.category, location: s.location, coordinates: s.coordinates, title: s.title }; }
        for (const c of nops.clear) { const n = notes.get(c); if (n) n.initial = null; }
        lines.push(`已记下照片记录：写 ${nops.set.length} / 删 ${nops.clear.length}（共 ${jn.count} 条；只写主库 .pm/vault-notes.json，上线时 /photo-publish 读它）`);
      }
      // 3) 再按类目生成推送计划（没有类目指派、也没有 DRIFT 就跳过）
      const assignments = [...snap.entries()].filter(([, c]) => c !== HOLD).map(([name, category]) => ({ name, category }));
      if (assignments.length || driftSnap) {
        const r = await post("/api/vault/push-plan", { assignments });
        const j = await r.json().catch(() => ({}));
        if (!r.ok) { out.className = "banner bad"; out.textContent = (lines.join("\n") + "\n未生成计划：" + (j.error || ("HTTP " + r.status)) + bodyLines(j)).trim(); btn.disabled = false; return; }
        lines.push(`已生成推送计划 ${j.plan.id}（${j.plan.items.length} 项）——只写了计划文件，照片未动。\n执行：${j.apply}\n计划文件：${j.path}` + (j.gitSteps.length ? "\n执行后的 git 步骤：\n" + j.gitSteps.join("\n") : ""));
      }
      out.className = "banner ok";
      out.textContent = lines.length ? lines.join("\n\n") : "没有需要保存的改动。";
      submitting = false;
      // 刷新失败不改判：计划已经生成，把它作为附注接在成功文案后面，别把
      // 横幅整段换成"请求失败"——那会让人以为计划没出来又点一次。
      try { await loadVault(); } catch (e) { out.textContent += "\n（网格刷新失败：" + e.message + "，按 4 重进本页）"; }
    } catch (e) {
      // e.message 里已经带着服务端的整段原因（get/bodyReason 会把 details /
      // lines 逐行拼进去），横幅是 pre-wrap，多行直接显示。
      out.className = "banner bad"; out.textContent = "请求失败：" + e.message; btn.disabled = false;
    }
    finally { submitting = false; }
  }
  // busy：提交期间 app.js 的导航按钮与数字键不切页（loadVault 会清空刚推进的 baseline）
  return { loadVault, makePlan, suggest, shrink, busy: () => submitting || suggesting };
};
