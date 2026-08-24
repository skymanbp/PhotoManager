// pm-ui frontend: vanilla JS, no bundler. Everything comes from `pm serve`
// over 127.0.0.1 with the session token handed over by the Rust shell.
(async function () {
  const $ = (s) => document.querySelector(s);
  const invoke = window.__TAURI__ && window.__TAURI__.core && window.__TAURI__.core.invoke;
  let api = null;

  async function connect() {
    if (!invoke) { throw new Error("不在 Tauri 里运行（缺 __TAURI__）"); }
    api = await invoke("api_info");
    $("#conn").textContent = "已连接 127.0.0.1:" + api.port;
  }

  async function get(path) {
    const r = await fetch("http://127.0.0.1:" + api.port + path, {
      headers: { Authorization: "Bearer " + api.token },
    });
    if (!r.ok) { throw new Error(path + " → HTTP " + r.status); }
    return r;
  }
  const getJson = async (p) => (await get(p)).json();

  // ── 仪表盘 ──
  async function loadStatus() {
    const s = await getJson("/api/status");
    if (!s.index) { $("#status-out").textContent = "主库尚未索引: " + s.root + "\n→ 运行 pm scan"; return; }
    const i = s.index;
    const gib = (b) => (b / 2 ** 30).toFixed(1);
    const lines = [
      `pm · 索引 ${i.scannedAt}（${i.ageMinutes} 分钟前）· ${i.files} 文件 / ${gib(i.bytes)} GiB`,
      "─".repeat(58),
      ...i.layers.map((l) => `  ${l.name.padEnd(14)} ${String(l.files).padStart(5)} 文件 ${gib(l.bytes).padStart(8)} GiB`),
      i.oldestVerifiedDays != null ? `  验证        最久未验证字节 ${i.oldestVerifiedDays} 天前` : null,
      i.stagingEvents.length ? `  暂存区    ${i.stagingEvents.length} 个事件 ${i.stagingFiles} 文件（已归档 ${i.stagingArchived}）` : null,
      `  备份盘     ${i.backup.state === "ok" ? "上次同步 " + i.backup.meta.at : i.backup.state === "absent" ? "未登记/未同步" : "⚠ 缓存不可信"}`,
      i.vault == null ? null : `  vault      ${i.vault.state === "ok" ? "上次比对 " + i.vault.meta.at + " · NEW " + i.vault.meta.new : i.vault.state}`,
      `  退出码 ${s.exit}`,
      ...s.warnings.map((w) => "⚠ " + w),
    ].filter((x) => x != null);
    $("#status-out").textContent = lines.join("\n");
  }

  // ── 计划 ──
  async function loadPlans() {
    const d = await getJson("/api/plans");
    const ul = $("#plan-list");
    ul.innerHTML = "";
    for (const p of d.plans) {
      const li = document.createElement("li");
      li.textContent = `${p.kind} · ${p.id} · ${p.items} 项（待执行 ${p.pending}，跳过 ${p.skipped}，待裁决 ${p.needsDecision}）`;
      li.onclick = async () => {
        for (const x of ul.children) x.classList.remove("sel");
        li.classList.add("sel");
        const plan = await getJson("/api/plan/" + p.id);
        $("#plan-detail").textContent = JSON.stringify(plan, null, 2);
      };
      ul.appendChild(li);
    }
    if (d.errors.length) {
      const li = document.createElement("li");
      li.textContent = "⚠ 装不出来的计划: " + JSON.stringify(d.errors);
      ul.appendChild(li);
    }
  }

  // ── 分类（vault NEW 看图）──
  // 十九轮 minor：blob URL 不 revoke 会随每次进入分类页累积（WebView 内存）。
  // 上一轮的 URL 在重建网格前逐个释放。
  let thumbUrls = [];
  async function loadVault() {
    const v = await getJson("/api/vault/status");
    $("#vault-summary").textContent =
      `相册 ${v.source_count} ↔ vault ${v.vault_count} · OK ${v.ok.length} · NEW ${v.new.length} · MISSING ${v.missing.length} · RENAME ${v.renamed.length} · DRIFT ${v.drift.length}`;
    const grid = $("#vault-grid");
    grid.innerHTML = "";
    for (const u of thumbUrls) URL.revokeObjectURL(u);
    thumbUrls = [];
    const meta = await getJson("/api/vault/new");
    for (const e of meta.new) {
      const card = document.createElement("div");
      card.className = "card";
      const img = document.createElement("img");
      img.alt = e.name;
      card.appendChild(img);
      const name = document.createElement("div");
      name.className = "name";
      name.textContent = e.name;
      card.appendChild(name);
      for (const c of ["landscape", "portrait", "urban"]) {
        const label = document.createElement("label");
        const rb = document.createElement("input");
        rb.type = "radio"; rb.name = "cat-" + e.name; rb.value = c;
        label.appendChild(rb); label.appendChild(document.createTextNode(c));
        card.appendChild(label);
      }
      grid.appendChild(card);
      // <img src> 带不了 Authorization 头 → fetch 成 blob
      try {
        const blob = await (await get("/api/thumb/" + e.sha)).blob();
        const url = URL.createObjectURL(blob);
        thumbUrls.push(url);
        img.src = url;
      } catch (err) { name.textContent += "（无缩略图: " + err.message + "）"; }
    }
  }

  // ── tabs ──
  const loaders = { status: loadStatus, plans: loadPlans, vault: loadVault };
  for (const b of document.querySelectorAll("nav button")) {
    b.onclick = async () => {
      for (const x of document.querySelectorAll("nav button")) x.classList.remove("active");
      for (const x of document.querySelectorAll(".tab")) x.classList.remove("active");
      b.classList.add("active");
      $("#tab-" + b.dataset.tab).classList.add("active");
      try { await loaders[b.dataset.tab](); } catch (e) { $("#conn").textContent = "⚠ " + e.message; }
    };
  }

  try {
    await connect();
    await loadStatus();
  } catch (e) {
    $("#conn").textContent = "⚠ " + e.message;
    $("#status-out").textContent = "无法连接 pm serve：" + e.message;
  }
})();
