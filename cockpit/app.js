(() => {
  "use strict";

  const moduleGrid = document.getElementById("module-grid");
  const template = document.getElementById("module-card-template");
  const refreshButton = document.getElementById("refresh-button");
  const notice = document.getElementById("notice");
  const moduleCount = document.getElementById("module-count");
  const runningCount = document.getElementById("running-count");
  const backupRoot = document.getElementById("backup-root");

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

  function statusText(module) {
    if (module.type === "system") return "Online";
    if (module.status === "running") return "Running";
    if (module.status === "partial") return "Partial";
    if (module.status === "stopped") return "Stopped";
    return module.status || "Unknown";
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
        showNotice(`${action[0].toUpperCase()}${action.slice(1)} for ${module.name} is not wired yet. Discovery UI is active.`, "info");
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

  refreshButton.addEventListener("click", refresh);
  refresh();
})();
