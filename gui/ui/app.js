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
      const diff = v.new.length + v.missing.length + v.renamed.length + v.drift.length + v.unstable.length;
      const chip = $("#vault-chip"); chip.textContent = diff === 0 ? "已同步" : `${diff} 项差异`; chip.className = "chip " + (diff === 0 ? "ok" : "warn");
      $("#vault-summary").textContent = `相册 ${v.source_count} 张 ↔ vault ${v.vault_count} 张 · ${v.vault_dir}`;
      const pills = $("#vault-pills"); pills.innerHTML = "";
      for (const [k, label] of [["ok", "一致"], ["new", "NEW 待推送"], ["missing", "vault 多出"], ["renamed", "改名"], ["drift", "内容漂移"], ["duplicate", "重复"], ["unpushable", "不可推"], ["unstable", "读取不稳"]]) {
        const p = el("span", "pill" + (k !== "ok" && v[k].length ? " hot" : ""), label); p.appendChild(el("b", null, String(v[k].length))); pills.appendChild(p);
      }
      const lists = $("#vault-lists"); lists.innerHTML = "";
      const mk = (title, arr, f) => { if (!arr.length) return; const d = el("details"); d.appendChild(el("summary", null, `${title}（${arr.length}）`)); const ul = el("ul"); for (const x of arr) ul.appendChild(el("li", null, f(x))); d.appendChild(ul); lists.appendChild(d); };
      mk("NEW —— 相册有、vault 没有（去「分类推送」）", v.new, (n) => n);
      mk("MISSING —— vault 有、相册没有（只报告，决定权在你）", v.missing, ([n, c]) => c + "/" + n);
      mk("RENAME —— 内容相同、名字不同（只报告）", v.renamed, ([n, m, c]) => `${n} ≡ ${c}/${m}`);
      mk("DRIFT —— 同名但内容不同（推送时出裁决计划）", v.drift, ([n, c]) => c + "/" + n);
      mk("UNSTABLE —— 读取期间在变化，稍后重试", v.unstable, ([n, loc]) => loc + "/" + n);
      if (v.new.length) steps.push([`${v.new.length} 张 NEW 待分类推送`, "去「分类推送」", "vault"]);
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
  const assign = new Map(); // name -> category
  async function shrink(blob) {
    // 原图动辄 10–75 MB：交给解码器按目标尺寸缩放，再转成小 JPEG，避免 15 张全分辨率位图撑爆 WebView。
    try {
      const bmp = await createImageBitmap(blob, { resizeWidth: 640, resizeQuality: "medium" });
      const cv = document.createElement("canvas"); cv.width = bmp.width; cv.height = bmp.height;
      cv.getContext("2d").drawImage(bmp, 0, 0); bmp.close();
      return await new Promise((res) => cv.toBlob((b) => res(b || blob), "image/jpeg", 0.85));
    } catch { return blob; }
  }
  function updateProgress(total) {
    $("#assign-progress").textContent = `已选 ${assign.size} / ${total}`;
    $("#btn-plan").disabled = assign.size === 0;
  }
  async function loadVault() {
    const grid = $("#vault-grid"); grid.innerHTML = "";
    for (const u of thumbUrls) URL.revokeObjectURL(u); thumbUrls = [];
    assign.clear(); $("#plan-result").className = "banner hidden";
    let meta;
    try { meta = await getJson("/api/vault/new"); } catch (e) { grid.appendChild(el("div", "muted", "vault 未配置或不可用：" + e.message)); updateProgress(0); return; }
    updateProgress(meta.new.length);
    if (!meta.new.length) { grid.appendChild(el("div", "muted", "没有待推送的 NEW 照片——相册与 vault 已一致。")); return; }
    const cards = [];
    for (const e of meta.new) {
      const card = el("div", "gcard");
      const ph = el("div", "ph", "加载中…"); card.appendChild(ph);
      const body = el("div", "body"); body.appendChild(el("div", "name", e.name)); body.appendChild(el("div", "meta", e.size != null ? mib(e.size) : ""));
      const seg = el("div", "seg");
      for (const c of meta.categories) {
        const b = el("button", null, c);
        b.onclick = () => { assign.set(e.name, c); for (const x of seg.children) x.classList.toggle("on", x === b); card.classList.add("done"); updateProgress(meta.new.length); };
        seg.appendChild(b);
      }
      body.appendChild(seg); card.appendChild(body); grid.appendChild(card);
      cards.push([e, ph]);
    }
    // 顺序拉图（每张原图可能几十 MB），缩小后再挂上去
    for (const [e, ph] of cards) {
      try {
        if (!e.sha) throw new Error("catalog 无 sha");
        const blob = await (await get("/api/thumb/" + e.sha)).blob();
        const small = await shrink(blob);
        const url = URL.createObjectURL(small); thumbUrls.push(url);
        const img = document.createElement("img"); img.alt = e.name; img.src = url;
        ph.textContent = ""; ph.appendChild(img);
      } catch (err) { ph.textContent = "无缩略图：" + err.message; }
    }
  }
  async function makePlan() {
    const btn = $("#btn-plan"); btn.disabled = true;
    const out = $("#plan-result");
    const body = { assignments: [...assign.entries()].map(([name, category]) => ({ name, category })) };
    try {
      const r = await req("/api/vault/push-plan", { method: "POST", headers: { Authorization: "Bearer " + api.token, "Content-Type": "application/json" }, body: JSON.stringify(body) });
      const j = await r.json();
      if (!r.ok) { out.className = "banner bad"; out.textContent = "未生成计划：" + (j.error || r.status) + (j.details ? "\n" + j.details.join("\n") : ""); btn.disabled = false; return; }
      out.className = "banner ok";
      out.textContent = `已生成推送计划 ${j.plan.id}（${j.plan.items.length} 项）——只写了计划文件，照片未动。\n执行：${j.apply}\n计划文件：${j.path}` + (j.gitSteps.length ? "\n执行后的 git 步骤：\n" + j.gitSteps.join("\n") : "");
    } catch (e) { out.className = "banner bad"; out.textContent = "请求失败：" + e.message; btn.disabled = false; }
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

  // ── tabs / buttons ──
  const loaders = { status: () => loadStatus(false), plans: loadPlans, vault: loadVault, help: async () => {} };
  async function showTab(name) {
    for (const x of document.querySelectorAll("nav button")) x.classList.toggle("active", x.dataset.tab === name);
    for (const x of document.querySelectorAll(".tab")) x.classList.toggle("active", x.id === "tab-" + name);
    // 把焦点放到内容区：PgDn/End/方向键直接滚动，不用先点一下
    const m = document.querySelector("main"); m.tabIndex = -1; m.focus({ preventScroll: true }); m.scrollTop = 0;
    try { await loaders[name](); } catch (e) { fail(e); }
  }
  for (const b of document.querySelectorAll("nav button")) b.onclick = () => showTab(b.dataset.tab);
  // 数字键 1–4 切页（键盘党；也是自动化截图验证用的入口）
  const keys = { "1": "status", "2": "vault", "3": "plans", "4": "help" };
  document.addEventListener("keydown", (ev) => { if (keys[ev.key] && !ev.ctrlKey && !ev.altKey && ev.target.tagName !== "INPUT") showTab(keys[ev.key]); });
  $("#btn-fresh").onclick = () => loadStatus(true).catch(fail);
  $("#btn-reload").onclick = () => loadStatus(false).catch(fail);
  $("#btn-plans-reload").onclick = () => loadPlans().catch(fail);
  $("#btn-plan").onclick = () => makePlan();

  try { await connect(); await loadStatus(false); } catch (e) { fail(e); $("#status-banner").className = "banner bad"; $("#status-banner").textContent = "无法连接 pm serve：" + e.message; }
})();
