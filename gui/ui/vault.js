// pm-ui「分类推送」页（P8-A 自 app.js 拆出，代码逐字搬移，只把页面状态收进
// 一个工厂：app.js 触 750 行预算，而 P8 要往里加入口）。外链脚本、无内联；由
// app.js 用共享工具构造：
//   window.pmVault({ $, el, mib, get, getJson, post, stamp, stale, bodyLines })
//     → { loadVault, makePlan, busy }
// 只调三个端点：/api/vault/new（只读）、/api/vault/hold（记「暂不同步」决定）、
// /api/vault/push-plan（只生成计划文件）。页面永不直接碰照片，一切经 pm serve。
window.pmVault = function (u) {
  const { $, el, mib, get, getJson, post, stamp, stale, bodyLines } = u;
  let thumbUrls = [];
  let vaultDrift = 0; // 没有 NEW 但有 DRIFT 时，也能出纯裁决计划
  let heldInitial = new Set(); // 打开这一页时盘上已有的「暂不同步」决定
  let submitting = false;      // 提交期间冻结选择：两步必须看同一份快照
  const HOLD = "__hold__";     // 第四个按钮的哨兵值——它不是 vault 类目
  const assign = new Map(); // name -> category | HOLD
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
  function updateProgress(total) {
    const ops = holdOps();
    const cats = [...assign.values()].filter((c) => c !== HOLD).length;
    $("#assign-progress").textContent = `已定 ${assign.size} / ${total}（分类 ${cats} · 暂不同步 ${ops.count}）` + (vaultDrift ? ` · ${vaultDrift} 项 DRIFT 待裁决` : "");
    // DRIFT-only 的 vault（没有 NEW）也要能出纯裁决计划，否则按钮永远灰着（二十轮 minor）。
    $("#btn-plan").disabled = cats === 0 && vaultDrift === 0 && !ops.hold.length && !ops.unhold.length;
  }
  async function loadVault() {
    // single-flight：连按数字键 3 会并发起多轮，旧轮在新轮 revoke 之后
    // 还会继续下载原图并建 blob URL（codex 二十轮 minor）。用代号作废旧轮。
    const gen = stamp("vault");
    try {
      const grid = $("#vault-grid"); grid.innerHTML = "";
      for (const u of thumbUrls) URL.revokeObjectURL(u); thumbUrls = [];
      // 这里**不**清 #plan-result：makePlan 成功后紧接着调 loadVault 刷新网格，
      // 顺手就把刚写出来的「计划 id / 执行命令 / 计划文件路径」抹了——那是这一页
      // 唯一一次说出计划 id 的机会。横幅只在用户**开始新一轮**时清（makePlan 开头）。
      assign.clear(); vaultDrift = 0; heldInitial = new Set();
      let meta;
      try { meta = await getJson("/api/vault/new"); } catch (e) {
        if (stale("vault", gen)) return; // 旧轮失败：别动新一轮的网格
        grid.appendChild(el("div", "muted", "vault 未配置或不可用：" + e.message)); updateProgress(0); return;
      }
      if (stale("vault", gen)) return;
      vaultDrift = (meta.drift || []).length;
      heldInitial = new Set((meta.held || []).map((e) => e.name));
      for (const n of heldInitial) assign.set(n, HOLD); // 回显盘上已有的决定
      const items = (meta.new || []).concat(meta.held || []);
      updateProgress(items.length);
      if (!items.length) {
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
        // 三个 vault 类目 + 第四个「暂不同步」：后者不是 vault 目录，只是主库里
        // 的一条本地决定，随时能改回类目。
        for (const c of meta.categories.concat([HOLD])) {
          const b = el("button", c === HOLD ? "hold" : null, c === HOLD ? "暂不同步" : c);
          b.onclick = () => { if (submitting) return; assign.set(e.name, c); for (const x of seg.children) x.classList.toggle("on", x === b); card.classList.add("done"); updateProgress(items.length); };
          if (assign.get(e.name) === c) { b.classList.add("on"); card.classList.add("done"); }
          seg.appendChild(b);
        }
        body.appendChild(seg); card.appendChild(body); grid.appendChild(card);
        cards.push([e, ph]);
      }
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
  async function makePlan() {
    const btn = $("#btn-plan"); btn.disabled = true;
    const out = $("#plan-result");
    // 新一轮开始 = 上一轮的结论作废，只有这里清横幅（loadVault 不再碰它）。
    out.className = "banner hidden"; out.textContent = "";
    const lines = [];
    // 两步之间会 await：先把**全部**提交状态快照下来（选择 + DRIFT 数），
    // 提交期间点击、切页、数字键都不再改它（submitting）。
    const snap = new Map(assign);
    const driftSnap = vaultDrift;
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
        // 已落盘 → 立刻推进 baseline：第二步失败后重试不该再撤一次已撤的决定
        heldInitial = new Set(jh.held || []);
        lines.push(`已记下决定：暂不同步 +${ops.hold.length} / 恢复 ${ops.unhold.length}（名单共 ${jh.count} 条；只写主库 .pm，vault 与照片没动）`);
      }
      // 2) 再按类目生成推送计划（没有类目指派、也没有 DRIFT 就跳过）
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
      try { await loadVault(); } catch (e) { out.textContent += "\n（网格刷新失败：" + e.message + "，按 3 重进本页）"; }
    } catch (e) {
      // e.message 里已经带着服务端的整段原因（get/bodyReason 会把 details /
      // lines 逐行拼进去），横幅是 pre-wrap，多行直接显示。
      out.className = "banner bad"; out.textContent = "请求失败：" + e.message; btn.disabled = false;
    }
    finally { submitting = false; }
  }
  // busy：提交期间 app.js 的导航按钮与数字键不切页（loadVault 会清空刚推进的 baseline）
  return { loadVault, makePlan, busy: () => submitting };
};
