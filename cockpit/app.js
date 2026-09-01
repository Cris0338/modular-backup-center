(() => {
  "use strict";

  const moduleGrid = document.getElementById("module-grid");
  const template = document.getElementById("module-card-template");
  const refreshButton = document.getElementById("refresh-button");
  const notice = document.getElementById("notice");
  const moduleCount = document.getElementById("module-count");
  const runningCount = document.getElementById("running-count");
  const backupRoot = document.getElementById("backup-root");
  const actionModal = document.getElementById("action-modal");
  const actionModalKicker = document.getElementById("action-modal-kicker");
  const actionModalTitle = document.getElementById("action-modal-title");
  const actionModalBody = document.getElementById("action-modal-body");
  const actionModalClose = document.getElementById("action-modal-close");
  const actionModalX = document.getElementById("action-modal-x");

  function humanSize(bytes) {
    if (!Number.isFinite(bytes) || bytes <= 0) return "—";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let value = bytes;
    let index = 0;
    while (value >= 1024 && index < units.length - 1) {
      value /= 1024;
      index += 1;
    }
    const digits = value >= 10 || index === 0 ? 0 : 1;
    return `${value.toFixed(digits)} ${units[index]}`;
  }

  function formatDate(iso) {
    if (!iso) return "Never";
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return iso;
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: "short",
      timeStyle: "short",
    }).format(date);
  }

  function showNotice(message, kind = "info") {
    notice.textContent = message;
    notice.dataset.kind = kind;
    notice.hidden = false;
  }

  function clearNotice() {
    notice.hidden = true;
    notice.textContent = "";
    delete notice.dataset.kind;
  }

  function showActionModal({ title, message, kind = "info", kicker = "Modular Backup Center" }) {
    actionModalKicker.textContent = kicker;
    actionModalTitle.textContent = title;
    actionModalBody.textContent = message;
    actionModal.dataset.kind = kind;
    if (!actionModal.open) actionModal.showModal();
  }

  function closeActionModal() {
    if (actionModal.open) actionModal.close();
  }

  function statusText(module) {
    if (module.type === "system") return "Online";
    if (module.status === "running") return "Running";
    if (module.status === "partial") return "Partial";
    if (module.status === "stopped") return "Stopped";
    return module.status || "Unknown";
  }

  async function verifyModule(module, button) {
    clearNotice();
    const originalText = button.textContent;
    button.disabled = true;
    button.textContent = "Verifying…";

    try {
      const output = await cockpit.spawn(
        ["/usr/local/lib/modular-backup-center/mbcctl", "verify", module.backup_key],
        { superuser: "try", err: "message" }
      );
      const result = JSON.parse(output);
      if (!result.ok) {
        throw new Error(result.error || "Verification failed");
      }
      showActionModal({
        title: "Backup verified",
        kicker: module.name,
        kind: "success",
        message: `${result.backup} verified successfully. ${result.checked_files} checksum entries checked.`,
      });
    } catch (error) {
      showActionModal({
        title: "Verification failed",
        kicker: module.name,
        kind: "error",
        message: String(error),
      });
    } finally {
      button.disabled = false;
      button.textContent = originalText;
    }
  }

  function renderModule(module) {
    const fragment = template.content.cloneNode(true);
    const card = fragment.querySelector(".module-card");
    const status = fragment.querySelector(".status-pill");

    card.dataset.moduleId = module.id;
    if (module.type === "system") card.classList.add("system-card");

    fragment.querySelector(".module-type").textContent = module.type === "system"
      ? "HOST"
      : module.type.toUpperCase();
    fragment.querySelector(".module-name").textContent = module.name;

    status.textContent = statusText(module);
    status.dataset.status = module.status || "unknown";

    const backup = module.last_backup;
    fragment.querySelector(".last-backup").textContent = backup ? formatDate(backup.created_at) : "Never";
    fragment.querySelector(".backup-size").textContent = backup ? humanSize(backup.size_bytes) : "—";
    fragment.querySelector(".integrity").textContent = backup ? backup.integrity : "—";
    fragment.querySelector(".container-count").textContent = module.type === "system"
      ? "Host"
      : `${module.running_containers}/${module.containers}`;

    fragment.querySelectorAll("[data-action]").forEach((button) => {
      const action = button.dataset.action;
      button.addEventListener("click", () => {
        if (action === "verify") {
          verifyModule(module, button);
          return;
        }
        showActionModal({
          title: `${action[0].toUpperCase()}${action.slice(1)}`,
          kicker: module.name,
          kind: "info",
          message: "This action is not wired yet.",
        });
      });
    });

    return fragment;
  }

  function render(payload) {
    moduleGrid.replaceChildren();
    const modules = payload.modules || [];

    modules.forEach((module) => moduleGrid.appendChild(renderModule(module)));

    moduleCount.textContent = String(modules.length);
    runningCount.textContent = String(modules.filter((module) => module.status === "running").length);
    backupRoot.textContent = payload.backup_root || "—";

    if (payload.docker_error) {
      showNotice(`Docker discovery warning: ${payload.docker_error}`, "warning");
    }
  }

  async function refresh() {
    clearNotice();
    refreshButton.disabled = true;
    refreshButton.textContent = "Refreshing…";

    try {
      const output = await cockpit.spawn(
        ["/usr/local/lib/modular-backup-center/mbcctl", "discover"],
        { superuser: "try", err: "message" }
      );
      render(JSON.parse(output));
    } catch (error) {
      showNotice(`Unable to load modules: ${error}`, "error");
    } finally {
      refreshButton.disabled = false;
      refreshButton.textContent = "Refresh";
    }
  }

  actionModalClose.addEventListener("click", closeActionModal);
  actionModalX.addEventListener("click", closeActionModal);
  actionModal.addEventListener("click", (event) => {
    if (event.target === actionModal) closeActionModal();
  });
  refreshButton.addEventListener("click", refresh);
  refresh();
})();
