// pm-ui frontend: vanilla JS, no bundler. Everything comes from `pm serve`
// over 127.0.0.1 with the session token handed over by the Rust shell.
// Five plan-free writes: POST /api/vault/push-plan and /api/sort/plan（只生成
// 计划文件）、/api/vault/hold（记一条「暂不同步」决定）、/api/config、
// /api/backup-init。P7 起（用户裁定 2026-08-26）Rust 壳以 --allow-apply 拉起
// serve：计划页可以点「执行」（两次点击确认）走 POST /api/apply——那是唯一会
// 动照片字节的端点，执行链与 CLI 的 pm apply 同源。git 仍只生成命令不执行（I9）。
(async function () {
  const $ = (s) => document.querySelector(s);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const gib = (b) => (b / 2 ** 30).toFixed(1) + " GiB";
  const mib = (b) => (b / 2 ** 20).toFixed(1) + " MB";
  const when = (iso) => { try { return new Date(iso).toLocaleString("zh-CN", { hour12: false }); } catch { return iso; } };
  const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
  let api = null;
  let allowApply = false; // /api/ping 的事实：没有第三级授权就不渲染「执行」按钮

  async function connect() {
    if (!invoke) throw new Error("不在 Tauri 里运行（缺 __TAURI__）");
    api = await invoke("api_info");
    const c = $("#conn"); c.textContent = "已连接 127.0.0.1:" + api.port; c.className = "conn ok";
    const p = await getJson("/api/ping");
    allowApply = !!p.allowApply;
    $("#root-path").textContent = p.main;
  }
  async function req(path, opts) {
    // 根修（P7）：此前这里对 opts 浅合并——调用方一传自己的 headers，整个
    // headers 对象把缺省那份**替换**掉，Authorization 随之丢失（sort 页
    // 生成计划自 P5-E 起 401 即此因）。授权头统一在这里并入，调用方只声明
    // 自己的增量头，别处不再各自拼 Authorization。
    const o = opts || {};
    const headers = Object.assign({ Authorization: "Bearer " + api.token }, o.headers || {});
    return fetch("http://127.0.0.1:" + api.port + path, Object.assign({}, o, { headers }));
  }
  // 4xx/5xx 的 JSON 体：`{"error": …}` 一行，`details`/`lines` 数组每项一行。
  // 服务端两个键都用过（details = 校验清单，lines = 逐行日志），一起认。
  const bodyLines = (j) => { const a = j && (j.lines || j.details); return Array.isArray(a) && a.length ? "\n" + a.join("\n") : ""; };
  // 错误响应体里写着**为什么**（服务端的 err 一律 JSON，个别路径是纯文本）。
  // 此前 get 只抛状态码，把这段原因丢在地上——横幅上只剩一个数字，用户既
  // 不知道是没配 vault 还是锁被占。读出来一并抛，多行原样保留（横幅 pre-wrap）。
  async function bodyReason(r) {
    let t;
    try { t = (await r.text()).trim(); } catch { return ""; }
    if (!t) return "";
    try {
      const j = JSON.parse(t);
      if (j && typeof j === "object") {
        const s = (j.error != null ? String(j.error) : "") + bodyLines(j);
        if (s.trim()) return s;
      }
    } catch { /* 不是 JSON：原文照抛 */ }
    return t;
  }
  async function get(path) {
    const r = await req(path);
    if (!r.ok) { const why = await bodyReason(r); throw new Error(path + " → HTTP " + r.status + (why ? " " + why : "")); }
    return r;
  }
  const getJson = async (p) => (await get(p)).json();
  function fail(e) { const c = $("#conn"); c.textContent = "⚠ " + e.message; c.className = "conn bad"; }
  // 「最新请求胜出」（40 轮 #5 的类级修法）：每个视图一个代号，await 回来时
  // 代号已变就丢弃这次响应——快速连点/切页/键盘会让旧响应晚到并覆盖新
  // 选择；计划明细乱序时「执行」按钮绑的就是旧计划。凡是会被用户重复触发、
  // 且渲染依赖「当前选择」的加载器一律走它，不各自发明。41 轮 #2：**失败
  // 路径同样适用**——旧请求晚到的异常会经 catch/.catch 改写画面（连接横幅、
  // 卡片、明细区）。每个加载器整体包一层 try/catch：stale 的异常丢弃，当前
  // 代的异常照抛给调用方既有的兜底。
  const gens = {};
  const stamp = (k) => (gens[k] = (gens[k] || 0) + 1);
  const stale = (k, g) => g !== gens[k];

  // ── 状态 ──
  const LAYER = { Raw: ["Raw 原片", "var(--raw)"], "成片": ["成片", "var(--proc)"], "相册": ["相册（收藏）", "var(--album)"], "To-Be-Sync'd": ["暂存区", "var(--stage)"] };
  async function loadStatus(fresh) {
    const gen = stamp("status");
    try {
      const s = await getJson("/api/status" + (fresh ? "?fresh=1" : ""));
      if (stale("status", gen)) return;
      const banner = $("#status-banner"); banner.className = "banner hidden"; banner.textContent = "";
      const steps = [];
      if (!s.index) {
        banner.className = "banner warn"; banner.textContent = "主库尚未索引：" + s.root + "\n→ 在终端运行 pm scan（首次全量约 10–25 分钟）";
        $("#layer-cards").innerHTML = ""; return;
      }
      const i = s.index;
      $("#index-meta").textContent = `索引于 ${when(i.scannedAt)}（${i.ageMinutes} 分钟前）· ${i.files} 文件 · ${gib(i.bytes)}`;
      // 分层卡片
      const cards = $("#layer-cards"); cards.innerHTML = "";
      const order = ["Raw", "成片", "相册", "To-Be-Sync'd"];
      const byName = Object.fromEntries(i.layers.map((l) => [l.name, l]));
      for (const n of order.concat(i.layers.map((l) => l.name).filter((n) => !order.includes(n)))) {
        const l = byName[n]; if (!l) continue;
        const [label, color] = LAYER[n] || [n, "var(--accent)"];
        const c = el("div", "card");
        c.style.setProperty("--c", color);
        const k = el("div", "k"); k.appendChild(el("span", null, label)); k.appendChild(el("span", null, gib(l.bytes)));
        c.appendChild(k);
        c.appendChild(el("div", "v", l.files.toLocaleString() + " 文件"));
        c.appendChild(el("div", "s", (100 * l.bytes / Math.max(1, i.bytes)).toFixed(0) + "% 的容量"));
        const bar = el("div", "bar"); const fill = el("i"); fill.style.width = (100 * l.bytes / Math.max(1, i.bytes)).toFixed(1) + "%"; bar.appendChild(fill); c.appendChild(bar);
        cards.appendChild(c);
      }
      // 新鲜度（与 Pm.Status 的渲染同一口径：读取错误也计入，不隐身）
      const fl = $("#fresh-line");
      if (i.freshness) {
        const f = i.freshness, errs = f.errors || 0, n = f.new + f.changed + f.missing + errs;
        fl.textContent = n === 0 ? "✓ 索引与磁盘一致" : `⚠ 索引已过期或核对受阻：新增 ${f.new} / 变更 ${f.changed} / 消失 ${f.missing} / 读取错误 ${errs} → 在终端运行 pm scan`;
        if (n) steps.push(["索引已过期或核对受阻", "pm scan"]);
      } else fl.textContent = "（未核对新鲜度——点右上「核对新鲜度」做一次 stat 级比对，约 2 秒）";
      if (i.oldestVerifiedDays != null) fl.textContent += ` · 最久未验证字节 ${i.oldestVerifiedDays} 天前`;
      if (i.stagingEvents.length) {
        const all = i.stagingFiles > 0 && i.stagingArchived === i.stagingFiles;
        steps.push(all ? [`暂存区 ${i.stagingEvents.length} 个事件 ${i.stagingFiles} 文件已全部归档（冗余）`, "pm clean staging（需插备份盘）"] : [`暂存区 ${i.stagingEvents.length} 个事件未归档`, "pm import"]);
      }
      // 备份盘
      const bchip = $("#backup-chip"), bsum = $("#backup-summary"), bdet = $("#backup-detail");
      const b = i.backup;
      if (b.state === "absent") { bchip.textContent = "未登记"; bchip.className = "chip"; bsum.textContent = "还没有登记备份盘"; bdet.textContent = "插上硬盘后在终端运行：pm backup init <盘上镜像路径>，再 pm backup。之后这里会显示上次同步时间与滞后量。"; steps.push(["备份盘未登记", "pm backup init <镜像路径> → pm backup"]); }
      else if (b.state === "untrusted") { bchip.textContent = "缓存不可信"; bchip.className = "chip bad"; bsum.textContent = b.error; bdet.textContent = "人工核查 .pm/backup-cache"; steps.push(["备份缓存不可信", "人工核查"]); }
      else { const m = b.meta, lag = m.add + m.update; bchip.textContent = lag === 0 ? "上次同步无滞后" : `落后 ${lag} 项`; bchip.className = "chip " + (lag === 0 ? "ok" : "warn"); bsum.textContent = `上次同步 ${when(m.at)} · ${m.path}`; bdet.textContent = `待新增 ${m.add} · 待更新 ${m.update} · 备份盘多出 ${m.extra}（EXTRA 只报告，永不删）。插盘后运行 pm backup 刷新。`; if (lag) steps.push([`备份盘落后 ${lag} 项`, "插盘后 pm backup"]); }
      // vault（用完整差异接口，"差哪些"）
      let vaultFailed = false;
      try {
        const v = await getJson("/api/vault/status");
        if (stale("status", gen)) return;
        // held 是 new 的注解子集（六态集合不变）：算"还差多少"时要扣掉
        const held = (v.held || []).length;
        const diff = v.new.length - held + v.missing.length + v.renamed.length + v.drift.length + v.unstable.length;
        const chip = $("#vault-chip"); chip.textContent = diff === 0 ? "已同步" : `${diff} 项差异`; chip.className = "chip " + (diff === 0 ? "ok" : "warn");
        $("#vault-summary").textContent = `相册 ${v.source_count} 张 ↔ vault ${v.vault_count} 张 · ${v.vault_dir}`;
        const pills = $("#vault-pills"); pills.innerHTML = "";
        for (const [k, label] of [["ok", "一致"], ["new", "NEW 待推送"], ["held", "暂不同步"], ["missing", "vault 多出"], ["renamed", "改名"], ["drift", "内容漂移"], ["duplicate", "重复"], ["unpushable", "不可推"], ["unstable", "读取不稳"]]) {
          const arr = v[k] || [];
          // NEW 的数字扣掉已决定不同步的；held 自己不算"热"（它是已经做过的决定）
          const n = k === "new" ? arr.length - held : arr.length;
          const p = el("span", "pill" + (k !== "ok" && k !== "held" && n ? " hot" : ""), label); p.appendChild(el("b", null, String(n))); pills.appendChild(p);
        }
        const lists = $("#vault-lists"); lists.innerHTML = "";
        const mk = (title, arr, f) => { if (!arr.length) return; const d = el("details"); d.appendChild(el("summary", null, `${title}（${arr.length}）`)); const ul = el("ul"); for (const x of arr) ul.appendChild(el("li", null, f(x))); d.appendChild(ul); lists.appendChild(d); };
        const heldNames = new Set((v.held || []).map(([n]) => n));
        mk("NEW —— 相册有、vault 没有（去「分类推送」）", v.new.filter((n) => !heldNames.has(n)), (n) => n);
        mk("暂不同步 —— 你决定先不放进 vault（随时可改）", v.held || [], ([n]) => n);
        mk("暂不同步 · 决定已失效（回到 NEW）", v.held_stale || [], ([n, why]) => n + "：" + why);
        mk("MISSING —— vault 有、相册没有（只报告，决定权在你）", v.missing, ([n, c]) => c + "/" + n);
        mk("RENAME —— 内容相同、名字不同（只报告）", v.renamed, ([n, m, c]) => `${n} ≡ ${c}/${m}`);
        mk("DRIFT —— 同名但内容不同（推送时出裁决计划）", v.drift, ([n, c]) => c + "/" + n);
        mk("UNSTABLE —— 读取期间在变化，稍后重试", v.unstable, ([n, loc]) => loc + "/" + n);
        const newActive = v.new.length - held;
        if (newActive) steps.push([`${newActive} 张 NEW 待分类推送`, "去「分类推送」", "vault"]);
        if ((v.held_stale || []).length) steps.push([`${v.held_stale.length} 条「暂不同步」已失效（照片换过）`, "去「分类推送」重新决定", "vault"]);
        // 按钮名只有一个：分类推送页的 #btn-plan =「保存决定并生成推送计划」。
        // 这里、空网格提示、上手页三处此前各叫各的，用户按名字找不到按钮。
        if (v.drift.length) steps.push([`${v.drift.length} 张 DRIFT 待裁决`, "「保存决定并生成推送计划」后 pm resolve"]);
      } catch (e) {
        if (stale("status", gen)) return; // 41 轮 #2：stale 失败不许改画面
        // 三态，别压成两态：「没配 vault」是**状态载荷**说的（i.vault === null
        // ⇔ 配置里没有 vault 路径），不是从抛出的异常猜的。网络断了、500、
        // root 锁被占（409）同样会走到这个 catch——那是**读取失败**，必须挂
        // bad 并把原因写出来；此前一律显示中性的"未配置"，读不出来看着像
        // 没配置，用户会去设置页反复填一个早就填好的路径。
        const chip = $("#vault-chip");
        $("#vault-pills").innerHTML = ""; $("#vault-lists").innerHTML = "";
        if (i.vault == null) {
          chip.textContent = "未配置"; chip.className = "chip";
          $("#vault-summary").textContent = "配置里还没有 vault 展示集目录——在「设置」页填一个。";
        } else {
          vaultFailed = true;
          chip.textContent = "读取失败"; chip.className = "chip bad";
          $("#vault-summary").textContent = e.message;
        }
      }
      // 下一步
      const ns = $("#next-steps"); ns.innerHTML = "";
      // 有区块没载出来就不能说"没有待办"——那是把未知说成已知（vault 差异
      // 可能正好是待办本身）。
      if (!steps.length && !vaultFailed && !s.warnings.length) ns.appendChild(el("li", null, "✓ 没有待办：索引、vault、备份都无需动作。"));
      if (vaultFailed) ns.appendChild(el("li", null, "⚠ vault 状态没读出来，上面的清单可能不全——看 vault 卡片里的原因。"));
      for (const [what, how, tab] of steps) { const li = el("li"); li.appendChild(el("span", null, what + " → ")); if (tab) { const a = el("a", null, how); a.onclick = () => showTab(tab); li.appendChild(a); } else li.appendChild(el("code", null, how)); ns.appendChild(li); }
      for (const w of s.warnings) { const li = el("li", null, "⚠ " + w); ns.appendChild(li); }
    } catch (e) {
      if (stale("status", gen)) return; // stale 失败不许改画面（41 轮 #2）
      throw e; // 当前代的失败照旧交给调用方兜底（fail 横幅等）
    }
  }

  // ── 分类推送 ──
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
  const post = (path, body) => req(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

  // ── 上线命令（P7）──
  // 文本由服务端 GET /api/publish-commands 生成（Pm.Publish，纯函数）；这里
  // 只复制。pm 从不执行 git（I9）——粘贴与回车都在用户终端。
  async function toClipboard(text) {
    try { await navigator.clipboard.writeText(text); return true; } catch {
      const ta = document.createElement("textarea");
      ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
      document.body.appendChild(ta); ta.select();
      try { return document.execCommand("copy"); } finally { ta.remove(); }
    }
  }
  async function copyPublishCommands() {
    const note = $("#publish-note"); note.classList.remove("hidden");
    try {
      const r = await req("/api/publish-commands");
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { note.textContent = "⚠ " + (j.error || ("HTTP " + r.status)); return; }
      const text = j.commands.join("\n");
      const ok = await toClipboard(text);
      note.textContent = ok
        ? `✓ 已复制 ${j.commands.length} 行命令——粘进终端，看清每一行再回车（pm 不执行 git）。`
        : "⚠ 复制失败——命令如下，请手动选取：\n" + text;
    } catch (e) { note.textContent = "⚠ 请求失败：" + e.message; }
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

  // ── 计划 ──
  async function loadPlans() {
    const gen = stamp("plans");
    try {
      const d = await getJson("/api/plans");
      if (stale("plans", gen)) return;
      const tb = $("#plan-table tbody"); tb.innerHTML = "";
      $("#plan-detail").innerHTML = ""; $("#plan-detail").appendChild(el("div", "muted", d.plans.length ? "选一个计划查看明细" : "还没有计划"));
      const sorted = d.plans.slice().sort((a, b) => (a.created < b.created ? 1 : -1));
      for (const p of sorted) {
        const tr = el("tr");
        const td0 = el("td"); td0.appendChild(el("span", "badge " + p.kind, p.kind)); tr.appendChild(td0);
        tr.appendChild(el("td", null, p.id)); tr.appendChild(el("td", null, when(p.created)));
        tr.appendChild(el("td", null, String(p.items))); tr.appendChild(el("td", null, String(p.pending))); tr.appendChild(el("td", null, String(p.skipped))); tr.appendChild(el("td", null, String(p.needsDecision)));
        tr.onclick = () => {
          for (const x of tb.children) x.classList.remove("sel"); tr.classList.add("sel");
          // 先把明细区清成占位再去取：载失败时留在页上的会是**上一个**计划的
          // 明细，而高亮行已经换成了刚点的这一行——看着就像点开了它。
          const box = $("#plan-detail"); box.innerHTML = ""; box.appendChild(el("div", "muted", "载入中…"));
          showPlan(p.id).catch((e) => {
            box.innerHTML = ""; box.appendChild(el("div", "muted", "载不出这个计划"));
            const b = $("#apply-result"); b.className = "banner bad"; b.textContent = "载不出计划 " + p.id + "：" + e.message;
          });
        };
        tb.appendChild(tr);
      }
      if (d.errors.length) { const tr = el("tr"); const td = el("td", "muted", "⚠ 装不出来的计划：" + d.errors.map((e) => e[0] + "：" + e[1]).join("；")); td.colSpan = 7; tr.appendChild(td); tb.appendChild(tr); }
      // 打开即显示最新计划的明细，不用先点
      if (sorted.length) { tb.firstChild.classList.add("sel"); await showPlan(sorted[0].id); }
    } catch (e) {
      if (stale("plans", gen)) return; // stale 失败不许改画面（41 轮 #2）
      throw e; // 当前代的失败照旧交给调用方兜底（fail 横幅等）
    }
  }
  function opRow(it) {
    const op = it.op, st = it.status.s;
    const tr = el("tr");
    tr.appendChild(el("td", null, String(it.ix != null ? it.ix : "")));
    const kind = op.t === "copy" ? "拷贝" : op.t === "rename" ? "改名" : op.t === "quarantine" ? "隔离" : op.t;
    tr.appendChild(el("td", "op", kind));
    const path = op.t === "copy" ? `${op.src} → ${op.dst}` : op.t === "rename" ? `${op.old} → ${op.new}` : op.t === "quarantine" ? `${op.victim}（${op.reason}）` : JSON.stringify(op);
    tr.appendChild(el("td", null, path));
    const tds = el("td"); tds.appendChild(el("span", "st " + st, st === "pending" ? "待执行" : st === "skipped" ? "跳过" : "待裁决" + (it.status.why ? "：" + it.status.why : ""))); tr.appendChild(tds);
    return tr;
  }
  async function showPlan(id) {
    // 明细与「执行」按钮绑定的是**这份响应**的计划：旧响应晚到必须丢弃，否则
    // 用户按 B 的选择意图点两下、执行的却是 A（40 轮 #5）。
    const gen = stamp("plan");
    try {
      const plan = await getJson("/api/plan/" + id);
      if (stale("plan", gen)) return;
      const box = $("#plan-detail"); box.innerHTML = "";
      box.appendChild(el("h3", null, `${plan.kind} · ${plan.id}`));
      box.appendChild(el("div", "muted small", `root ${plan.rootPath || plan.root || ""} · 生成于 ${when(plan.created)} · 终端执行：`)).appendChild(el("code", null, "pm apply " + plan.id));
      const t = el("table", "items"); for (const it of plan.items) t.appendChild(opRow(it)); box.appendChild(t);
      // 执行入口（P7）：只有 serve 带第三级授权（--allow-apply，pm ui 拉起即是）
      // 且计划里有待执行项才渲染。两次点击确认——没有弹窗原语，同一个按钮先
      // arm 再确认，5 秒不点第二下自动解除。
      const pending = plan.items.filter((it) => it.status && it.status.s === "pending").length;
      if (allowApply && pending > 0) {
        const row = el("div", "exec-row");
        const label = `执行这个计划（${pending} 项待执行）`;
        const btn = el("button", "btn danger", label);
        let armed = false, timer = null, armedAt = 0;
        const ARM_DWELL_MS = 400; // 双击/键盘连发落在这个窗口里，不算"第二下"
        const disarm = () => { armed = false; armedAt = 0; clearTimeout(timer); btn.classList.remove("armed"); btn.textContent = label; };
        btn.onclick = () => {
          if (!armed) {
            armed = true; armedAt = performance.now(); btn.classList.add("armed");
            // 确认文案带计划 id：看清要执行的是哪一份再点第二下
            btn.textContent = `⚠ 再点一次确认执行 ${plan.id}（5 秒内）`;
            // 两次点击确认的前提是**两次独立的意思表示**。焦点留在按钮上时，
            // 一次双击、或按住 Enter 的键盘连发，会在几十毫秒内送来第二个
            // click——那和第一下是同一个动作，却足以让照片开始搬。摘掉焦点
            // （挡住 Enter 连发）再加一段静默期（挡住双击），窗口期内的点击
            // 一概忽略且**保持** armed，用户重新点一下仍然生效。
            btn.blur();
            timer = setTimeout(disarm, 5000);
            return;
          }
          if (performance.now() - armedAt < ARM_DWELL_MS) return; // 太快 = 同一个动作，仍保持已确认态
          // 确认即**消费** armed（39 轮 #5）：此前这里不复位，请求失败后按钮
          // 恢复可点时仍处于已确认态——单击一次就能再执行。每次执行后回到
          // 全新未确认状态，失败重试也要重新点两下。
          disarm();
          applyPlan(plan.id, btn, label).catch(fail);
        };
        row.appendChild(btn);
        row.appendChild(el("span", "muted small", "两段式的第二段：校验写入 + 日志，事后可 pm undo。重复执行幂等（已落位的项按内容跳过）。"));
        box.appendChild(row);
      }
      const det = el("details"); det.appendChild(el("summary", "muted small", "原始 JSON")); det.appendChild(el("pre", "raw", JSON.stringify(plan, null, 2))); box.appendChild(det);
    } catch (e) {
      if (stale("plan", gen)) return; // stale 失败不许改画面（41 轮 #2）
      throw e; // 当前代的失败照旧交给调用方兜底（fail 横幅等）
    }
  }

  // 执行一个已存计划：串行（serve 侧有 seApplyLock + root 锁），结果与逐项
  // 输出全在 JSON 响应体里（serve 的 stdout 无人排空，不走 stdout）。
  async function applyPlan(id, btn, label) {
    const out = $("#apply-result");
    btn.disabled = true; btn.textContent = "执行中…（校验写入进行中，别关窗口）";
    try {
      const r = await post("/api/apply", { planId: id });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) {
        out.className = "banner bad";
        out.textContent = "没有执行：" + (j.error || ("HTTP " + r.status));
        return;
      }
      const counts = new Map();
      for (const it of j.items || []) counts.set(it.outcome, (counts.get(it.outcome) || 0) + 1);
      const summary = [...counts.entries()].map(([k, v]) => `${k} ×${v}`).join(" · ");
      const logTail = (j.log || []).slice(-8).join("\n");
      out.className = "banner " + (j.code === 0 ? "ok" : "warn");
      out.textContent =
        (j.code === 0 ? `✓ 执行完成：${j.planId}` : `执行结束（退出码 ${j.code}）：${j.planId}——有未完成/待裁决项，见逐项结果`) +
        (summary ? `\n逐项：${summary}` : "") +
        (logTail ? `\n${logTail}` : "") +
        "\n回滚：终端 pm undo。";
      await loadPlans();
    } catch (e) {
      out.className = "banner bad"; out.textContent = "请求失败：" + e.message;
    } finally {
      // 失败路径按钮还挂在页上：恢复成未确认原文案（armed 已在点击处消费）
      btn.disabled = false; btn.textContent = label;
    }
  }

  // ── 设置 ──
  const cfgTxt = (id, v) => { $(id).value = v == null ? "" : String(v); };
  async function loadConfig() {
    const gen = stamp("config");
    try {
      const c = await getJson("/api/config");
      if (stale("config", gen)) return;
      $("#config-path").textContent = "配置文件：" + c.configPath;
      const rootWord = { present: "身份就位", absent: "还没有 root 标识", corrupt: "root 标识损坏——人工核查", untrusted: "路径不可信——人工核查" };
      $("#cfg-main").textContent = c.main.path + "（" + (rootWord[c.main.root] || c.main.root) + (c.main.exists ? "" : " · 目录不存在") + "）";
      cfgTxt("#cfg-vault", c.vault && c.vault.path);
      const vn = $("#cfg-vault-note");
      if (!c.vault) vn.textContent = "未设：不设也能用，只是 vault 相关命令会提示补配置。";
      else if (!c.vault.exists) vn.textContent = "⚠ 目录不存在";
      else vn.textContent = "✓ 目录在" + (c.vault.i11 ? " · I11 就绪（.gitignore 已含 .pm/）" : " · ⚠ I11 未就绪：" + (c.vault.i11why || "在这个 git 工作树里建 root 会被拒"));
      cfgTxt("#cfg-photos", c.photosJson && c.photosJson.path);
      cfgTxt("#cfg-workers", c.workers);
      const pub = c.publish || {};
      cfgTxt("#cfg-portfolio-dir", pub.portfolioDir);
      cfgTxt("#cfg-vault-push", pub.vaultPush);
      cfgTxt("#cfg-portfolio-push", pub.portfolioPush);
      // /api/config 的 backup 恒是对象，两个字段各自可为 null（Serve.hs:425
      // `object ["id" .= cfgBackupId cfg, "subpath" .= cfgBackupSubpath cfg]`）。
      // 认盘要 UUID + 盘内相对路径**两样**：只看 id 会把手改 config.toml 落下的
      // 半登记态说成"已登记"，然后在 subpath 位置印一个 undefined。
      const bk = c.backup || {};
      const bkId = bk.id != null && bk.id !== "" ? bk.id : null;
      const bkSub = bk.subpath != null && bk.subpath !== "" ? bk.subpath : null;
      $("#cfg-backup").textContent = bkId && bkSub
        ? "已登记：UUID " + bkId + " · 盘内路径 " + bkSub + "（按 UUID 认盘，与盘符无关）"
        : bkId || bkSub
          ? "登记不完整（缺 " + (bkId ? "盘内相对路径 subpath" : "盘标识 id") + "）——在下面重新登记一次这块盘"
          : "未登记";
    } catch (e) {
      if (stale("config", gen)) return; // stale 失败不许改画面（41 轮 #2）
      throw e; // 当前代的失败照旧交给调用方兜底（fail 横幅等）
    }
  }
  function cfgBanner(ok, text) { const b = $("#config-result"); b.className = "banner " + (ok ? "ok" : "bad"); b.textContent = text; }
  // 提交结果与**刷新**状态分开报：写入一旦成功，后面重载页面失败也不能把横幅
  // 改回"没改成"——那会让人以为配置没落盘、再改一遍。
  async function saveConfig(patch) {
    let r, j;
    try {
      r = await post("/api/config", patch);
      j = await r.json();
    } catch (e) { cfgBanner(false, "请求失败：" + e.message); return; }
    if (!r.ok) { cfgBanner(false, "没改成：" + (j.error || r.status) + (j.details ? "\n" + j.details.join("\n") : "")); return; }
    const okMsg = "✓ 已写入 " + j.configPath + "——已经生效，不用重启。";
    cfgBanner(true, okMsg);
    try {
      await loadConfig();
      await loadStatus(false).catch(() => {});
    } catch (e) { cfgBanner(true, okMsg + "\n（页面刷新失败：" + e.message + "，按 5 重进设置页即可看到最新值）"); }
  }
  async function registerBackup() {
    const p = $("#cfg-backup-path").value.trim();
    if (!p) { cfgBanner(false, "先填盘上的镜像路径，如 E:\\Photography"); return; }
    try {
      const r = await post("/api/backup-init", { path: p });
      const j = await r.json();
      if (!r.ok) { cfgBanner(false, "登记失败：" + (j.error || r.status) + (j.details ? "\n" + j.details.join("\n") : "")); return; }
      const okMsg = (j.reused ? "✓ 该路径已是备份 root，沿用标识 " : "✓ 已在该路径建立备份 root 标识 ") + j.id + "\n下一步：在终端跑 pm backup 做一次同步。";
      cfgBanner(true, okMsg);
      // 同 saveConfig：登记已经成功，刷新失败不改判。
      try { await loadConfig(); } catch (e2) { cfgBanner(true, okMsg + "\n（页面刷新失败：" + e2.message + "）"); }
    } catch (e) { cfgBanner(false, "请求失败：" + e.message); }
  }

  // ── tabs / buttons ──
  // ── 整理新照片（第二页）──
  // 只调两个端点：/api/sort/survey（只读提议）与 /api/sort/plan（写 .pm/plans，
  // 不碰照片）。页面**不**执行任何计划——那是计划页/终端的事。
  let lastSurvey = null;
  function sortNote(kind, text) {
    const b = $("#sort-result"); b.className = "banner " + kind; b.textContent = text;
  }
  async function sortScan() {
    const src = $("#sort-src").value.trim();
    if (!src) { sortNote("warn", "先填一个源目录（相机卡或下载目录）"); return; }
    const gap = Number($("#sort-gap").value) || 72;
    $("#sort-result").className = "banner hidden";
    $("#sort-segments").innerHTML = ""; $("#sort-left").innerHTML = "";
    $("#sort-summary").textContent = "扫描中…（读 EXIF 拍摄时间，不改动源目录）";
    // 同一类竞态：换了源目录再点一次，旧源的提议晚到会把「生成计划」绑到
    // 旧的 sv.src 上——计划生成会落到错的目录。
    const gen = stamp("sort");
    try {
      const r = await req("/api/sort/survey?src=" + encodeURIComponent(src) + "&gap=" + gap);
      const body = await r.json().catch(() => ({}));
      if (stale("sort", gen)) return;
      if (!r.ok) { $("#sort-summary").textContent = ""; sortNote("bad", body.error || ("HTTP " + r.status)); return; }
      lastSurvey = body;
      renderSurvey(body);
    } catch (e) {
      if (stale("sort", gen)) return; // stale 失败不许改画面（41 轮 #2）
      throw e; // 当前代的失败照旧交给调用方兜底（fail 横幅等）
    }
  }
  function renderSurvey(sv) {
    $("#sort-summary").textContent =
      `源 ${sv.src} · 照片 ${sv.photos} 个：可定时 ${sv.dated} · 读不到拍摄时间 ${sv.undated.length}` +
      ` · 候选分段 ${sv.segments.length}（间隔 > ${sv.gapHours} 小时切一刀）· 侧车 ${sv.sidecars} 个`;
    const box = $("#sort-segments"); box.innerHTML = "";
    if (!sv.segments.length) { box.appendChild(el("div", "muted", "没有可定时的照片——下面列出的每一类都不会被归位。")); }
    for (const g of sv.segments) {
      // 类名是 sort-seg 不是 seg：分类推送页的类目按钮行也叫 .seg，两套规则
      // （这边的卡片有 border/padding/background）会串到那边的按钮行上。
      const c = el("div", "sort-seg");
      const head = el("div", "seg-head");
      head.appendChild(el("span", "seg-when", `段 ${g.index}　${g.firstAt} → ${g.lastAt}`));
      head.appendChild(el("span", "seg-meta", `${g.count} 张　首 ${base(g.firstFile)} · 尾 ${base(g.lastFile)}`));
      c.appendChild(head);
      const row = el("div", "seg-row");
      const place = el("input"); place.type = "text"; place.placeholder = "地点，如 Atlanta（相机没有 GPS，只能你给）";
      // dataset.event 是「并入已有事件」按钮打的标记，生成计划时它压过输入框
      // 的文本。用户点完再手改文字，标记必须作废——否则计划按旧事件名落，
      // 屏幕上显示的却是新名字。
      place.addEventListener("input", () => { delete place.dataset.event; });
      const from = el("input"); from.type = "date"; from.value = g.from;
      const to = el("input"); to.type = "date"; to.value = g.to;
      const btn = el("button", "btn primary", "生成计划");
      row.append(place, from, to, btn);
      c.appendChild(row);
      if (g.sameMonthEvents.length) {
        const m = el("div", "seg-merge");
        m.appendChild(el("span", null, "↺ 已有同年月事件："));
        for (const ev of g.sameMonthEvents) {
          const a = el("button", "btn ghost", ev);
          a.title = "并入这个已有事件夹（用完整事件名，不再自动拼年月）";
          a.onclick = () => { place.value = ev; place.dataset.event = "1"; };
          m.appendChild(a);
        }
        m.appendChild(el("span", null, " —— 点一下并入它"));
        c.appendChild(m);
      }
      // 兜底 .catch：makeSortPlan 里 try 之前那几行（读输入框）真抛了，
      // 异步函数只会静静地 reject 到控制台，页面上一点动静都没有。
      btn.onclick = () => { makeSortPlan(sv.src, place, from.value, to.value, btn).catch((e) => sortNote("bad", "请求失败：" + e.message)); };
      box.appendChild(c);
    }
    const left = $("#sort-left"); left.innerHTML = "";
    bucket(left, "读不到拍摄时间", sv.undated, "不猜——请自行放置或先补 EXIF");
    bucket(left, "无主侧车", sv.homelessSidecars, "同目录同 stem 找不到主文件");
    bucket(left, "不认识的扩展名", sv.unknown, "不归位，但一定列出来");
    bucket(left, "遍历错误", sv.errors.map((e) => e.path + " — " + e.why), "");
    for (const n of sv.notes) left.appendChild(el("div", "muted small", "· " + n));
  }
  const base = (p) => p.split(/[\\/]/).pop();
  function bucket(host, title, xs, why) {
    if (!xs || !xs.length) return;
    const d = el("details"); d.appendChild(el("summary", null, `${title} ${xs.length} 个${why ? "（" + why + "）" : ""}`));
    const ul = el("ul", "steps");
    for (const x of xs.slice(0, 200)) ul.appendChild(el("li", "mono small", x));
    if (xs.length > 200) ul.appendChild(el("li", "muted small", `…另有 ${xs.length - 200} 个`));
    d.appendChild(ul); host.appendChild(d);
  }
  async function makeSortPlan(src, placeInput, from, to, btn) {
    const v = placeInput.value.trim();
    if (!v) { sortNote("warn", "先填地点（或点上面的已有事件名并入）"); return; }
    btn.disabled = true;
    try {
      const isEvent = placeInput.dataset.event === "1";
      const payload = { src, from, to };
      payload[isEvent ? "event" : "place"] = v;
      const r = await post("/api/sort/plan", payload);
      const body = await r.json().catch(() => ({}));
      if (!r.ok) { sortNote("bad", (body.error || ("HTTP " + r.status)) + bodyLines(body)); return; }
      if (body.planId) {
        sortNote("ok", `计划已生成：${body.planId}\n下一步到「计划」页查看明细并执行（或在终端 pm apply ${body.planId}）`);
      } else {
        // 「详情见终端」在 GUI 下是句空话：pm ui 拉起的 serve，stdout 挂在
        // 空设备上，没有哪个终端会印出来。逐行日志由响应体带回来（log），
        // 直接摆在横幅里；老服务端没这个字段就至少把退出码说清楚。
        const log = (body.log || []).join("\n");
        sortNote("warn", "没有生成计划——这一段里没有可归位的文件，或有需要你先处理的冲突。\n" + (log || `退出码 ${body.code}`));
      }
      await loadPlans().catch(() => {});
    } catch (e) {
      sortNote("bad", "请求失败：" + e.message);
    } finally { btn.disabled = false; }
  }

  const loaders = { status: () => loadStatus(false), sort: async () => {}, plans: loadPlans, vault: loadVault, config: loadConfig, help: async () => {} };
  async function showTab(name) {
    for (const x of document.querySelectorAll("nav button")) x.classList.toggle("active", x.dataset.tab === name);
    for (const x of document.querySelectorAll(".tab")) x.classList.toggle("active", x.id === "tab-" + name);
    // 把焦点放到内容区：PgDn/End/方向键直接滚动，不用先点一下
    const m = document.querySelector("main"); m.tabIndex = -1; m.focus({ preventScroll: true }); m.scrollTop = 0;
    try { await loaders[name](); } catch (e) { fail(e); }
  }
  for (const b of document.querySelectorAll("nav button")) b.onclick = () => { if (submitting) return; showTab(b.dataset.tab); };
  // 数字键 1–6 切页（键盘党；也是自动化截图验证用的入口）
  const keys = { "1": "status", "2": "sort", "3": "vault", "4": "plans", "5": "config", "6": "help" };
  document.addEventListener("keydown", (ev) => {
    if (submitting) return; // 提交期间不切页：loadVault 会清空刚推进的 baseline
    if (ev.repeat || ev.ctrlKey || ev.altKey || ev.metaKey) return; // 长按连发 → 并发重载
    const t = ev.target;
    if (t && (t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName))) return;
    if (keys[ev.key]) showTab(keys[ev.key]);
  });
  $("#btn-sort-scan").onclick = () => sortScan().catch(fail);
  $("#sort-src").addEventListener("keydown", (e) => { if (e.key === "Enter") sortScan().catch(fail); });
  $("#btn-fresh").onclick = () => loadStatus(true).catch(fail);
  $("#btn-reload").onclick = () => loadStatus(false).catch(fail);
  $("#btn-plans-reload").onclick = () => loadPlans().catch(fail);
  $("#btn-plan").onclick = () => makePlan();
  // 设置页的按钮全部经 cfgClick：处理器是 async，没有 .catch 的异常只会
  // 落进控制台——按钮看着像点过了，配置其实一个字节没改。异常（含 try 之前
  // 读输入框那几行的同步抛出）一律渲染进本页自己的横幅 #config-result。
  const cfgClick = (id, fn) => {
    $(id).onclick = () => {
      try { const p = fn(); if (p && typeof p.catch === "function") p.catch((e) => cfgBanner(false, "操作失败：" + e.message)); }
      catch (e) { cfgBanner(false, "操作失败：" + e.message); }
    };
  };
  cfgClick("#btn-config-reload", () => loadConfig());
  const val = (id) => $(id).value.trim();
  cfgClick("#btn-cfg-vault", () => saveConfig({ vault: val("#cfg-vault") }));
  cfgClick("#btn-cfg-vault-clear", () => saveConfig({ vault: null }));
  cfgClick("#btn-cfg-photos", () => saveConfig({ photosJson: val("#cfg-photos") }));
  cfgClick("#btn-cfg-photos-clear", () => saveConfig({ photosJson: null }));
  cfgClick("#btn-cfg-workers", () => saveConfig({ workers: Number(val("#cfg-workers")) }));
  cfgClick("#btn-cfg-workers-clear", () => saveConfig({ workers: null }));
  // 上线命令三项：placeholder 写明「留空 = 默认」，因此空着点保存 = 清空
  // （null），而不是把空串塞给字符闸吃一个「不合法」。
  const valOrNull = (id) => { const v = val(id); return v === "" ? null : v; };
  cfgClick("#btn-cfg-portfolio-dir", () => saveConfig({ portfolioDir: valOrNull("#cfg-portfolio-dir") }));
  cfgClick("#btn-cfg-portfolio-dir-clear", () => saveConfig({ portfolioDir: null }));
  cfgClick("#btn-cfg-vault-push", () => saveConfig({ vaultPush: valOrNull("#cfg-vault-push") }));
  cfgClick("#btn-cfg-vault-push-clear", () => saveConfig({ vaultPush: null }));
  cfgClick("#btn-cfg-portfolio-push", () => saveConfig({ portfolioPush: valOrNull("#cfg-portfolio-push") }));
  cfgClick("#btn-cfg-portfolio-push-clear", () => saveConfig({ portfolioPush: null }));
  cfgClick("#btn-cfg-backup", () => registerBackup());
  $("#btn-publish-copy").onclick = () => copyPublishCommands();

  try { await connect(); await loadStatus(false); } catch (e) { fail(e); $("#status-banner").className = "banner bad"; $("#status-banner").textContent = "无法连接 pm serve：" + e.message; }
})();
