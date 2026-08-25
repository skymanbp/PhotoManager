// pm-ui frontend: vanilla JS, no bundler. Everything comes from `pm serve`
// over 127.0.0.1 with the session token handed over by the Rust shell.
// The only write is POST /api/vault/push-plan (generates a plan file; nothing
// is executed here — apply stays a terminal step until it gets its own
// reviewed endpoint).
(async function () {
  const $ = (s) => document.querySelector(s);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const gib = (b) => (b / 2 ** 30).toFixed(1) + " GiB";
  const mib = (b) => (b / 2 ** 20).toFixed(1) + " MB";
  const when = (iso) => { try { return new Date(iso).toLocaleString("zh-CN", { hour12: false }); } catch { return iso; } };
  const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
  let api = null;

  async function connect() {
    if (!invoke) throw new Error("不在 Tauri 里运行（缺 __TAURI__）");
    api = await invoke("api_info");
    const c = $("#conn"); c.textContent = "已连接 127.0.0.1:" + api.port; c.className = "conn ok";
    const p = await getJson("/api/ping");
    $("#root-path").textContent = p.main;
  }
  async function req(path, opts) {
    const r = await fetch("http://127.0.0.1:" + api.port + path, Object.assign({ headers: { Authorization: "Bearer " + api.token } }, opts || {}));
    return r;
  }
  async function get(path) { const r = await req(path); if (!r.ok) throw new Error(path + " → HTTP " + r.status); return r; }
  const getJson = async (p) => (await get(p)).json();
  function fail(e) { const c = $("#conn"); c.textContent = "⚠ " + e.message; c.className = "conn bad"; }

  // ── 状态 ──
  const LAYER = { Raw: ["Raw 原片", "var(--raw)"], "成片": ["成片", "var(--proc)"], "相册": ["相册（收藏）", "var(--album)"], "To-Be-Sync'd": ["暂存区", "var(--stage)"] };
  async function loadStatus(fresh) {
    const s = await getJson("/api/status" + (fresh ? "?fresh=1" : ""));
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
    // 新鲜度
    const fl = $("#fresh-line");
    if (i.freshness) {
      const f = i.freshness, n = f.new + f.changed + f.missing;
      fl.textContent = n === 0 ? "✓ 索引与磁盘一致" : `⚠ 索引已过期：新增 ${f.new} / 变更 ${f.changed} / 消失 ${f.missing} → 在终端运行 pm scan`;
      if (n) steps.push(["索引已过期", "pm scan"]);
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
    try {
      const v = await getJson("/api/vault/status");
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
      if (v.drift.length) steps.push([`${v.drift.length} 张 DRIFT 待裁决`, "生成推送计划后 pm resolve"]);
    } catch (e) { $("#vault-chip").textContent = "未配置"; $("#vault-chip").className = "chip"; $("#vault-summary").textContent = e.message; }
    // 下一步
    const ns = $("#next-steps"); ns.innerHTML = "";
    if (!steps.length) ns.appendChild(el("li", null, "✓ 没有待办：索引、vault、备份都无需动作。"));
    for (const [what, how, tab] of steps) { const li = el("li"); li.appendChild(el("span", null, what + " → ")); if (tab) { const a = el("a", null, how); a.onclick = () => showTab(tab); li.appendChild(a); } else li.appendChild(el("code", null, how)); ns.appendChild(li); }
    for (const w of s.warnings) { const li = el("li", null, "⚠ " + w); ns.appendChild(li); }
  }

  // ── 分类推送 ──
  let thumbUrls = [];
  let vaultGen = 0;   // single-flight 代号：新一轮作废旧一轮
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
    // single-flight：连按数字键 2 会并发起多轮，旧轮在新轮 revoke 之后
    // 还会继续下载原图并建 blob URL（codex 二十轮 minor）。用代号作废旧轮。
    const gen = ++vaultGen;
    const grid = $("#vault-grid"); grid.innerHTML = "";
    for (const u of thumbUrls) URL.revokeObjectURL(u); thumbUrls = [];
    assign.clear(); vaultDrift = 0; heldInitial = new Set(); $("#plan-result").className = "banner hidden";
    let meta;
    try { meta = await getJson("/api/vault/new"); } catch (e) {
      if (gen !== vaultGen) return; // 旧轮失败：别动新一轮的网格
      grid.appendChild(el("div", "muted", "vault 未配置或不可用：" + e.message)); updateProgress(0); return;
    }
    if (gen !== vaultGen) return;
    vaultDrift = (meta.drift || []).length;
    heldInitial = new Set((meta.held || []).map((e) => e.name));
    for (const n of heldInitial) assign.set(n, HOLD); // 回显盘上已有的决定
    const items = (meta.new || []).concat(meta.held || []);
    updateProgress(items.length);
    if (!items.length) {
      grid.appendChild(el("div", "muted", vaultDrift
        ? `没有待推送的 NEW；但有 ${vaultDrift} 项 DRIFT（同名、内容不同）——点「生成推送计划」出一份纯裁决计划，再在终端 pm resolve。`
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
      if (gen !== vaultGen) return; // 已被新一轮取代：不再下载、不再建 URL
      try {
        if (!e.sha) throw new Error("catalog 无 sha");
        const blob = await (await get("/api/thumb/" + e.sha)).blob();
        const small = await shrink(blob);
        if (gen !== vaultGen) return;
        if (!small) { ph.textContent = "缩略失败（不挂原图）"; continue; }
        const url = URL.createObjectURL(small); thumbUrls.push(url);
        const img = document.createElement("img"); img.alt = e.name; img.src = url;
        ph.textContent = ""; ph.appendChild(img);
      } catch (err) { ph.textContent = "无缩略图：" + err.message; }
    }
  }
  const post = (path, body) => req(path, { method: "POST", headers: { Authorization: "Bearer " + api.token, "Content-Type": "application/json" }, body: JSON.stringify(body) });
  async function makePlan() {
    const btn = $("#btn-plan"); btn.disabled = true;
    const out = $("#plan-result");
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
        const jh = await rh.json();
        if (!rh.ok) { out.className = "banner bad"; out.textContent = "决定未保存：" + (jh.error || rh.status) + (jh.details ? "\n" + jh.details.join("\n") : ""); btn.disabled = false; return; }
        // 已落盘 → 立刻推进 baseline：第二步失败后重试不该再撤一次已撤的决定
        heldInitial = new Set(jh.held || []);
        lines.push(`已记下决定：暂不同步 +${ops.hold.length} / 恢复 ${ops.unhold.length}（名单共 ${jh.count} 条；只写主库 .pm，vault 与照片没动）`);
      }
      // 2) 再按类目生成推送计划（没有类目指派、也没有 DRIFT 就跳过）
      const assignments = [...snap.entries()].filter(([, c]) => c !== HOLD).map(([name, category]) => ({ name, category }));
      if (assignments.length || driftSnap) {
        const r = await post("/api/vault/push-plan", { assignments });
        const j = await r.json();
        if (!r.ok) { out.className = "banner bad"; out.textContent = (lines.join("\n") + "\n未生成计划：" + (j.error || r.status) + (j.details ? "\n" + j.details.join("\n") : "")).trim(); btn.disabled = false; return; }
        lines.push(`已生成推送计划 ${j.plan.id}（${j.plan.items.length} 项）——只写了计划文件，照片未动。\n执行：${j.apply}\n计划文件：${j.path}` + (j.gitSteps.length ? "\n执行后的 git 步骤：\n" + j.gitSteps.join("\n") : ""));
      }
      out.className = "banner ok";
      out.textContent = lines.length ? lines.join("\n\n") : "没有需要保存的改动。";
      submitting = false;
      await loadVault();
    } catch (e) { out.className = "banner bad"; out.textContent = "请求失败：" + e.message; btn.disabled = false; }
    finally { submitting = false; }
  }

  // ── 计划 ──
  async function loadPlans() {
    const d = await getJson("/api/plans");
    const tb = $("#plan-table tbody"); tb.innerHTML = "";
    $("#plan-detail").innerHTML = ""; $("#plan-detail").appendChild(el("div", "muted", d.plans.length ? "选一个计划查看明细" : "还没有计划"));
    const sorted = d.plans.slice().sort((a, b) => (a.created < b.created ? 1 : -1));
    for (const p of sorted) {
      const tr = el("tr");
      const td0 = el("td"); td0.appendChild(el("span", "badge " + p.kind, p.kind)); tr.appendChild(td0);
      tr.appendChild(el("td", null, p.id)); tr.appendChild(el("td", null, when(p.created)));
      tr.appendChild(el("td", null, String(p.items))); tr.appendChild(el("td", null, String(p.pending))); tr.appendChild(el("td", null, String(p.skipped))); tr.appendChild(el("td", null, String(p.needsDecision)));
      tr.onclick = async () => { for (const x of tb.children) x.classList.remove("sel"); tr.classList.add("sel"); await showPlan(p.id); };
      tb.appendChild(tr);
    }
    if (d.errors.length) { const tr = el("tr"); const td = el("td", "muted", "⚠ 装不出来的计划：" + d.errors.map((e) => e[0] + "：" + e[1]).join("；")); td.colSpan = 7; tr.appendChild(td); tb.appendChild(tr); }
    // 打开即显示最新计划的明细，不用先点
    if (sorted.length) { tb.firstChild.classList.add("sel"); await showPlan(sorted[0].id); }
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
    const plan = await getJson("/api/plan/" + id);
    const box = $("#plan-detail"); box.innerHTML = "";
    box.appendChild(el("h3", null, `${plan.kind} · ${plan.id}`));
    box.appendChild(el("div", "muted small", `root ${plan.rootPath || plan.root || ""} · 生成于 ${when(plan.created)} · 执行：`)).appendChild(el("code", null, "pm apply " + plan.id));
    const t = el("table", "items"); for (const it of plan.items) t.appendChild(opRow(it)); box.appendChild(t);
    const det = el("details"); det.appendChild(el("summary", "muted small", "原始 JSON")); det.appendChild(el("pre", "raw", JSON.stringify(plan, null, 2))); box.appendChild(det);
  }

  // ── 设置 ──
  const cfgTxt = (id, v) => { $(id).value = v == null ? "" : String(v); };
  async function loadConfig() {
    const c = await getJson("/api/config");
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
    $("#cfg-backup").textContent = c.backup && c.backup.id
      ? "已登记：UUID " + c.backup.id + " · 盘内路径 " + c.backup.subpath + "（按 UUID 认盘，与盘符无关）"
      : "未登记";
  }
  function cfgBanner(ok, text) { const b = $("#config-result"); b.className = "banner " + (ok ? "ok" : "bad"); b.textContent = text; }
  async function saveConfig(patch) {
    try {
      const r = await post("/api/config", patch);
      const j = await r.json();
      if (!r.ok) { cfgBanner(false, "没改成：" + (j.error || r.status) + (j.details ? "\n" + j.details.join("\n") : "")); return; }
      cfgBanner(true, "✓ 已写入 " + j.configPath + "——已经生效，不用重启。");
      await loadConfig();
      await loadStatus(false).catch(() => {});
    } catch (e) { cfgBanner(false, "请求失败：" + e.message); }
  }
  async function registerBackup() {
    const p = $("#cfg-backup-path").value.trim();
    if (!p) { cfgBanner(false, "先填盘上的镜像路径，如 E:\\Photography"); return; }
    try {
      const r = await post("/api/backup-init", { path: p });
      const j = await r.json();
      if (!r.ok) { cfgBanner(false, "登记失败：" + (j.error || r.status) + (j.details ? "\n" + j.details.join("\n") : "")); return; }
      cfgBanner(true, (j.reused ? "✓ 该路径已是备份 root，沿用标识 " : "✓ 已在该路径建立备份 root 标识 ") + j.id + "\n下一步：在终端跑 pm backup 做一次同步。");
      await loadConfig();
    } catch (e) { cfgBanner(false, "请求失败：" + e.message); }
  }

  // ── tabs / buttons ──
  const loaders = { status: () => loadStatus(false), plans: loadPlans, vault: loadVault, config: loadConfig, help: async () => {} };
  async function showTab(name) {
    for (const x of document.querySelectorAll("nav button")) x.classList.toggle("active", x.dataset.tab === name);
    for (const x of document.querySelectorAll(".tab")) x.classList.toggle("active", x.id === "tab-" + name);
    // 把焦点放到内容区：PgDn/End/方向键直接滚动，不用先点一下
    const m = document.querySelector("main"); m.tabIndex = -1; m.focus({ preventScroll: true }); m.scrollTop = 0;
    try { await loaders[name](); } catch (e) { fail(e); }
  }
  for (const b of document.querySelectorAll("nav button")) b.onclick = () => { if (submitting) return; showTab(b.dataset.tab); };
  // 数字键 1–4 切页（键盘党；也是自动化截图验证用的入口）
  const keys = { "1": "status", "2": "vault", "3": "plans", "4": "config", "5": "help" };
  document.addEventListener("keydown", (ev) => {
    if (submitting) return; // 提交期间不切页：loadVault 会清空刚推进的 baseline
    if (ev.repeat || ev.ctrlKey || ev.altKey || ev.metaKey) return; // 长按连发 → 并发重载
    const t = ev.target;
    if (t && (t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName))) return;
    if (keys[ev.key]) showTab(keys[ev.key]);
  });
  $("#btn-fresh").onclick = () => loadStatus(true).catch(fail);
  $("#btn-reload").onclick = () => loadStatus(false).catch(fail);
  $("#btn-plans-reload").onclick = () => loadPlans().catch(fail);
  $("#btn-plan").onclick = () => makePlan();
  $("#btn-config-reload").onclick = () => loadConfig().catch(fail);
  const val = (id) => $(id).value.trim();
  $("#btn-cfg-vault").onclick = () => saveConfig({ vault: val("#cfg-vault") });
  $("#btn-cfg-vault-clear").onclick = () => saveConfig({ vault: null });
  $("#btn-cfg-photos").onclick = () => saveConfig({ photosJson: val("#cfg-photos") });
  $("#btn-cfg-photos-clear").onclick = () => saveConfig({ photosJson: null });
  $("#btn-cfg-workers").onclick = () => saveConfig({ workers: Number(val("#cfg-workers")) });
  $("#btn-cfg-workers-clear").onclick = () => saveConfig({ workers: null });
  $("#btn-cfg-backup").onclick = () => registerBackup();

  try { await connect(); await loadStatus(false); } catch (e) { fail(e); $("#status-banner").className = "banner bad"; $("#status-banner").textContent = "无法连接 pm serve：" + e.message; }
})();
