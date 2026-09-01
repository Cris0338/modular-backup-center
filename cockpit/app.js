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
  const actionModalConfirm = document.getElementById("action-modal-confirm");
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

  function resetModalControls() {
    actionModalClose.disabled = false;
    actionModalClose.textContent = "Close";
    actionModalX.disabled = false;
    actionModalConfirm.hidden = true;
    actionModalConfirm.disabled = false;
    actionModalConfirm.textContent = "Continue";
    actionModalConfirm.onclick = null;
  }

  function showActionModal({ title, message = "", kind = "info", kicker = "Modular Backup Center" }) {
    resetModalControls();
    actionModalKicker.textContent = kicker;
    actionModalTitle.textContent = title;
    actionModalBody.textContent = message;
    actionModal.dataset.kind = kind;
    if (!actionModal.open) actionModal.showModal();
  }

  function closeActionModal() {
    if (actionModalClose.disabled) return;
    if (actionModal.open) actionModal.close();
  }

  function setModalBusy(label) {
    actionModalClose.disabled = true;
    actionModalX.disabled = true;
    actionModalConfirm.hidden = false;
    actionModalConfirm.disabled = true;
    actionModalConfirm.textContent = label;
  }

  function statusText(module) {
    if (module.type === "system") return "Online";
    if (module.status === "running") return "Running";
    if (module.status === "partial") return "Partial";
    if (module.status === "stopped") return "Stopped";
    return module.status || "Unknown";
  }

  function actionAvailable(module, action) {
    if ((module.capabilities || []).includes(action)) return true;

    // Known adapters may intentionally be root-only. Discovery runs
    // unprivileged, while write/destructive actions use Cockpit superuser.
    if (action === "backup" && module.adapter && module.adapter !== "generic") {
      return true;
    }
    if (action === "restore" && module.adapter === "openclaw") {
      return true;
    }

    return false;
  }

  function resultError(result, fallback) {
    if (!result || typeof result !== "object") return fallback;
    const details = Array.isArray(result.details) ? result.details.slice(-6) : [];
    const base = result.error || fallback;
    return details.length ? `${base}\n${details.join("\n")}` : base;
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
      if (!result.ok) throw new Error(resultError(result, "Verification failed"));
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

  async function backupModule(module, button) {
    clearNotice();
    const originalText = button.textContent;
    button.disabled = true;
    button.textContent = "Backing up…";

    showActionModal({
      title: "Backup in progress",
      kicker: module.name,
      kind: "info",
      message: "Creating a new backup and verifying its checksums. The module may be briefly stopped while its data is captured.",
    });

    try {
      const output = await cockpit.spawn(
        ["/usr/local/lib/modular-backup-center/mbcctl", "backup", module.backup_key],
        { superuser: "require", err: "message" }
      );
      const result = JSON.parse(output);
      if (!result.ok) throw new Error(resultError(result, "Backup failed"));

      const backup = result.last_backup || {};
      showActionModal({
        title: "Backup completed",
        kicker: module.name,
        kind: "success",
        message: `${result.backup} created and verified successfully. ${humanSize(backup.size_bytes)} · ${result.checked_files} checksum entries checked.`,
      });
      await refresh();
    } catch (error) {
      showActionModal({
        title: "Backup failed",
        kicker: module.name,
        kind: "error",
        message: String(error),
      });
    } finally {
      button.disabled = false;
      button.textContent = originalText;
    }
  }

  function renderRestoreConfirmation(module, backup, precheckResult) {
    showActionModal({
      title: "Confirm restore",
      kicker: module.name,
      kind: "warning",
    });

    actionModalClose.textContent = "Cancel";

    const form = document.createElement("div");
    form.className = "restore-form";

    const warning = document.createElement("p");
    warning.className = "restore-warning";
    warning.textContent = "Precheck passed. Restoring will stop this module, create a safety snapshot, replace its saved state and deployment files, then start it again and run a health check.";
    form.appendChild(warning);

    const summary = document.createElement("div");
    summary.className = "restore-summary";
    const backupLine = document.createElement("strong");
    backupLine.textContent = backup.name;
    const metadataLine = document.createElement("span");
    metadataLine.textContent = `${formatDate(backup.created_at)} · ${humanSize(backup.size_bytes)} · integrity ${backup.integrity || "unknown"}`;
    const checkLine = document.createElement("span");
    const finalDetail = Array.isArray(precheckResult.details) ? precheckResult.details.at(-1) : "Restore precheck passed";
    checkLine.textContent = finalDetail || "Restore precheck passed";
    summary.append(backupLine, metadataLine, checkLine);
    form.appendChild(summary);

    const confirmField = document.createElement("label");
    confirmField.className = "restore-field";
    const confirmLabel = document.createElement("span");
    confirmLabel.className = "field-label";
    confirmLabel.textContent = "Type RESTORE to confirm";
    const confirmInput = document.createElement("input");
    confirmInput.type = "text";
    confirmInput.autocomplete = "off";
    confirmInput.spellcheck = false;
    confirmInput.placeholder = "RESTORE";
    confirmField.append(confirmLabel, confirmInput);
    form.appendChild(confirmField);

    actionModalBody.replaceChildren(form);
    actionModalConfirm.hidden = false;
    actionModalConfirm.disabled = true;
    actionModalConfirm.textContent = "Restore backup";

    confirmInput.addEventListener("input", () => {
      actionModalConfirm.disabled = confirmInput.value !== "RESTORE";
    });

    actionModalConfirm.onclick = async () => {
      if (confirmInput.value !== "RESTORE") return;
      confirmInput.disabled = true;
      setModalBusy("Restoring…");

      try {
        const output = await cockpit.spawn(
          [
            "/usr/local/lib/modular-backup-center/mbcctl",
            "restore",
            module.backup_key,
            backup.name,
            "--confirm",
            "RESTORE",
          ],
          { superuser: "require", err: "message" }
        );
        const result = JSON.parse(output);
        if (!result.ok) throw new Error(resultError(result, "Restore failed"));

        const details = Array.isArray(result.details) ? result.details : [];
        const status = details.find((line) => line.startsWith("Status:"));
        const safety = details.find((line) => line.startsWith("Safety:"));
        const extra = [status, safety].filter(Boolean).join(" · ");
        showActionModal({
          title: "Restore completed",
          kicker: module.name,
          kind: "success",
          message: `${backup.name} restored successfully.${extra ? ` ${extra}` : ""}`,
        });
        await refresh();
      } catch (error) {
        showActionModal({
          title: "Restore failed",
          kicker: module.name,
          kind: "error",
          message: String(error),
        });
      }
    };

    confirmInput.focus();
  }

  async function restoreModule(module, button) {
    clearNotice();
    const originalText = button.textContent;
    button.disabled = true;
    button.textContent = "Loading…";

    try {
      const output = await cockpit.spawn(
        ["/usr/local/lib/modular-backup-center/mbcctl", "backups", module.backup_key],
        { superuser: "try", err: "message" }
      );
      const result = JSON.parse(output);
      if (!result.ok) throw new Error(resultError(result, "Unable to list backups"));

      const backups = Array.isArray(result.backups) ? result.backups : [];
      if (!backups.length) throw new Error("No backup is available for restore.");

      showActionModal({
        title: "Restore backup",
        kicker: module.name,
        kind: "warning",
      });
      actionModalClose.textContent = "Cancel";

      const form = document.createElement("div");
      form.className = "restore-form";

      const warning = document.createElement("p");
      warning.className = "restore-warning";
      warning.textContent = "Choose the backup to restore. MBC will verify checksums and compatibility before asking for final confirmation.";
      form.appendChild(warning);

      const backupField = document.createElement("label");
      backupField.className = "restore-field";
      const backupLabel = document.createElement("span");
      backupLabel.className = "field-label";
      backupLabel.textContent = "Backup";
      const select = document.createElement("select");
      backups.forEach((backup) => {
        const option = document.createElement("option");
        option.value = backup.name;
        option.textContent = `${formatDate(backup.created_at)} — ${humanSize(backup.size_bytes)} — ${backup.name}`;
        select.appendChild(option);
      });
      backupField.append(backupLabel, select);
      form.appendChild(backupField);

      actionModalBody.replaceChildren(form);
      actionModalConfirm.hidden = false;
      actionModalConfirm.textContent = "Run precheck";
      actionModalConfirm.onclick = async () => {
        const backup = backups.find((item) => item.name === select.value);
        if (!backup) return;

        select.disabled = true;
        setModalBusy("Checking…");
        try {
          const precheckOutput = await cockpit.spawn(
            [
              "/usr/local/lib/modular-backup-center/mbcctl",
              "restore-precheck",
              module.backup_key,
              backup.name,
            ],
            { superuser: "require", err: "message" }
          );
          const precheckResult = JSON.parse(precheckOutput);
          if (!precheckResult.ok) {
            throw new Error(resultError(precheckResult, "Restore precheck failed"));
          }
          renderRestoreConfirmation(module, backup, precheckResult);
        } catch (error) {
          showActionModal({
            title: "Restore precheck failed",
            kicker: module.name,
            kind: "error",
            message: String(error),
          });
        }
      };
    } catch (error) {
      showActionModal({
        title: "Restore unavailable",
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
      const available = actionAvailable(module, action);
      if (!available) {
        button.disabled = true;
        button.title = `${action} is not available for this module yet`;
      }

      button.addEventListener("click", () => {
        if (!available) return;
        if (action === "backup") {
          backupModule(module, button);
          return;
        }
        if (action === "verify") {
          verifyModule(module, button);
          return;
        }
        if (action === "restore") {
          restoreModule(module, button);
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
  actionModal.addEventListener("cancel", (event) => {
    if (actionModalClose.disabled) event.preventDefault();
  });
  refreshButton.addEventListener("click", refresh);
  refresh();
})();
