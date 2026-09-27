// pm-ui 跨页的一键动作（1.3.0，用户 2026-09-26「我在 GUI 怎么 pm scan？」+「一键打开命令行做
// GitHub 推送」+「傻瓜式 / 一键式」）。外链脚本、无内联；由 app.js 用共享工具构造：
//   window.pmActions({ $, el, post, getJson, invoke, showTab }) → { scan, openTerminal, goPlansBtn }
// 三件事都不碰照片：scan 走 POST /api/scan（与终端 pm scan 同一个 runScanTo，只写主库 .pm 的
// 索引）；openTerminal 经 Tauri command open_terminal 只开一个 cmd 窗口（pm 在 PATH 上），里面
// 敲什么由用户定——pm 从不替你执行 git（I9）；goPlansBtn 只是往横幅末尾挂一个跳到「计划」页的
// 按钮，执行仍在那边两次点击确认。
window.pmActions = function (u) {
  const { $, el, post, getJson, invoke, showTab } = u;
  let scanning = false; // 一次一个：状态页与归档页两处入口共用这一把
  // 扫描索引。box = 结果横幅（状态页 #scan-result，归档页 #archive-result）；返回是否成功（退出码 0/1
  // 都算扫完并已落盘，1 = 有要看的交代行；HTTP 非 200 / 请求失败 = false）。首次全量约 10–25 分钟，
  // 之后增量秒级——fetch 无超时，请求一直挂到 serve 答完。
  async function scan(box) {
    const btn = $("#btn-scan");
    if (scanning) { box.className = "banner warn"; box.textContent = "已经在扫描了——等这一轮结束。"; return false; }
    scanning = true; btn.disabled = true; btn.textContent = "扫描中…";
    box.className = "banner"; box.textContent = "扫描中…（读盘 + 给新文件算 sha；首次全量约 10–25 分钟，之后几秒。别关窗口）";
    try {
      const r = await post("/api/scan", {});
      const j = await r.json().catch(() => ({}));
      const log = (j.log || []).join("\n");
      if (!r.ok) { box.className = "banner bad"; box.textContent = "扫描没完成：" + (j.error || ("HTTP " + r.status)) + (log ? "\n" + log : ""); return false; }
      box.className = "banner " + (j.code === 0 ? "ok" : "warn");
      box.textContent = (j.code === 0 ? "✓ 扫描完成，索引已更新。" : "扫描完成，索引已更新——但有要看的：") + (log ? "\n" + log : "");
      return true;
    } catch (e) { box.className = "banner bad"; box.textContent = "请求失败：" + e.message; return false; }
    finally { scanning = false; btn.disabled = false; btn.textContent = "扫描"; }
  }
  // 打开命令行：目录按「展示集仓 → portfolio 仓 → 主库」取第一个配置了的（上线命令用 git -C <仓>，
  // 在哪个目录都能贴）。invoke 的失败是 Rust 侧的一句字符串，不是 Error 对象。
  async function openTerminal() {
    const note = $("#publish-note"); note.classList.remove("hidden");
    try {
      const c = await getJson("/api/config");
      const dir = (c.vault && c.vault.exists && c.vault.path) || (c.publish && c.publish.portfolioDir) || c.main.path;
      await invoke("open_terminal", { dir });
      note.textContent = "✓ 命令行已打开（目录 " + dir + "，pm 已在 PATH）——粘贴上线命令，看清每一行再回车。pm 不替你执行 git。";
    } catch (e) { note.textContent = "⚠ 打不开命令行：" + (e && e.message ? e.message : String(e)); }
  }
  // 出计划之后的一键跳转（横幅是 pre-wrap，先换行再挂按钮）。
  function goPlansBtn(box) {
    const b = el("button", "btn mini", "去「计划」页执行 ›");
    b.onclick = () => showTab("plans");
    box.appendChild(document.createTextNode("\n")); box.appendChild(b);
  }
  return { scan, openTerminal, goPlansBtn };
};
