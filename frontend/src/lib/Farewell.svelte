<script>
  // v1.2.0 "Farewell": the "LockPlus 2 is here" screen.
  //   intro  — what LockPlus 2 copies, end of updates, Move now / Later
  //   moved  — helper removed: download + verify LockPlus 2, open the installer
  import { createEventDispatcher, onMount, tick } from 'svelte';
  import { t } from '../i18n/index.js';
  import { errText } from './errors.js';

  export let TunnelService;
  export let status = null;       // FarewellStatus from Go
  export let dismissable = false; // opened from the banner while choice = later

  const dispatch = createEventDispatcher();

  let working = false;
  let notice = '';   // neutral (cancelled)
  let error = '';
  let downloading = false;
  let downloadError = '';
  let primaryBtn;
  let confirmTrash = false;

  $: moved = status?.choice === 'moved';
  // LockPlus 2 can't run on this Mac (macOS < 26): information only.
  $: unsupported = status && status.supported === false;
  $: blockedText = status?.blocked ? $t('farewell.blocked_' + status.blocked) : '';
  $: oldApps = status?.old_apps || [];
  $: busy = working || downloading || !!status?.busy;

  function setStatus(s) {
    if (!s) return;
    status = s;
    dispatch('status', s);
  }

  async function refresh() {
    try {
      setStatus(await TunnelService.GetFarewellStatus());
    } catch (e) {
      console.warn('farewell status failed:', e);
    }
  }

  onMount(async () => {
    await refresh();
    await tick();
    primaryBtn?.focus();
  });

  async function moveNow() {
    if (busy) return;
    working = true;
    notice = '';
    error = '';
    try {
      const s = await TunnelService.MoveToLockPlus2();
      setStatus(s);
      if (s?.cancelled) {
        notice = $t('farewell.cancelled');
      } else if (s?.choice === 'moved' && !s?.download_ready && !s?.remnants?.length) {
        working = false;
        await download(true);
      }
    } catch (e) {
      error = $t('farewell.failed', { error: errText(e) });
      await refresh();
    } finally {
      working = false;
    }
  }

  async function later() {
    if (busy) return;
    try {
      await TunnelService.FarewellLater();
    } catch (e) {
      // The state couldn't be saved; the helper starts anyway.
      console.warn('farewell later:', e);
    }
    await refresh();
    dispatch('close');
  }

  async function download(chained = false) {
    if (busy && !chained) return;
    downloading = true;
    downloadError = '';
    try {
      setStatus(await TunnelService.DownloadLockPlus2());
    } catch (e) {
      downloadError = $t('farewell.download_failed', { error: errText(e) });
      await refresh();
    } finally {
      downloading = false;
    }
  }

  async function openInstaller() {
    try {
      await TunnelService.OpenLockPlus2Installer();
    } catch (e) {
      downloadError = errText(e);
      await refresh();
    }
  }

  async function openPage() {
    try { await TunnelService.OpenLockPlus2DownloadPage(); } catch (e) { downloadError = errText(e); }
  }

  async function keepV1() {
    if (busy) return;
    try {
      await TunnelService.KeepUsingLockPlus1();
    } catch (e) {
      console.warn('keep using LockPlus 1:', e);
    }
    await refresh();
    dispatch('close');
  }

  async function trashOldApp() {
    confirmTrash = false;
    try {
      setStatus(await TunnelService.TrashOldApp());
    } catch (e) {
      error = errText(e);
      await refresh();
    }
  }

  function onKeydown(e) {
    if (e.key === 'Escape' && dismissable && !busy) dispatch('close');
  }
</script>

<svelte:window on:keydown={onKeydown} />

<div class="fw-backdrop" role="presentation">
  <div class="fw-modal" role="dialog" aria-modal="true" aria-labelledby="fw-title" aria-describedby="fw-desc">
    <img src="/appicon.png" class="fw-icon" alt="" />

    {#if unsupported}
      <h2 id="fw-title">{$t('farewell.title')}</h2>
      <p class="fw-sub" id="fw-desc">{$t('farewell.unsupported_body')}</p>
      <div class="fw-footer">
        <button class="fw-btn fw-primary" bind:this={primaryBtn} on:click={later} disabled={busy}>{$t('farewell.ok')}</button>
      </div>
    {:else if !moved}
      <h2 id="fw-title">{$t('farewell.title')}</h2>
      <p class="fw-sub" id="fw-desc">{$t('farewell.subtitle')}</p>

      <div class="fw-section">
        <h3>{$t('farewell.migrate_title')}</h3>
        <ul>
          <li>{$t('farewell.migrate_profiles')}</li>
          <li>{$t('farewell.migrate_policy')}</li>
          <li>{$t('farewell.migrate_wifi')}</li>
          <li>{$t('farewell.migrate_history')}</li>
          <li>{$t('farewell.migrate_credentials')}</li>
        </ul>
        <p class="fw-note">{$t('farewell.migrate_note')}</p>
      </div>

      <p class="fw-eol">{$t('farewell.eol')}</p>
      <p class="fw-explain">{$t('farewell.move_explain')}</p>
      <p class="fw-explain">{$t('farewell.later_explain')}</p>

      {#if working}
        <div class="fw-status" role="status"><span class="fw-spinner"></span>{$t('farewell.working')}</div>
      {/if}
      {#if notice}<div class="fw-status" role="status">{notice}</div>{/if}
      {#if blockedText}<div class="fw-error" role="alert">{blockedText}</div>{/if}
      {#if error}<div class="fw-error" role="alert">{error}</div>{/if}

      <div class="fw-footer">
        {#if dismissable}
          <button class="fw-btn fw-secondary" on:click={() => dispatch('close')} disabled={busy}>{$t('farewell.close')}</button>
        {:else}
          <button class="fw-btn fw-secondary" on:click={later} disabled={busy}>{$t('farewell.later')}</button>
        {/if}
        <button class="fw-btn fw-primary" bind:this={primaryBtn} on:click={moveNow} disabled={busy}>{$t('farewell.move_now')}</button>
      </div>
    {:else}
      <h2 id="fw-title">{$t('farewell.removed_title')}</h2>
      <p class="fw-sub" id="fw-desc">{$t('farewell.removed_body')}</p>
      {#if status?.remnants?.length}
        <div class="fw-error" role="alert">{$t('farewell.remnants', { items: status.remnants.join(', ') })}</div>
      {/if}
      {#if working}
        <div class="fw-status" role="status"><span class="fw-spinner"></span>{$t('farewell.working')}</div>
      {/if}
      {#if notice}<div class="fw-status" role="status">{notice}</div>{/if}
      {#if error}<div class="fw-error" role="alert">{error}</div>{/if}

      {#if downloading}
        <div class="fw-status" role="status"><span class="fw-spinner"></span>{$t('farewell.downloading')}</div>
      {:else if status?.download_ready}
        <div class="fw-ok" role="status">✓ {$t('farewell.verified', { version: status.new_version })}</div>
        <p class="fw-note">{$t('farewell.installer_hint')}</p>
        {#if status?.brew}<p class="fw-note">{$t('farewell.brew_hint')}</p>{/if}
      {/if}
      {#if downloadError}<div class="fw-error" role="alert">{downloadError}</div>{/if}
      {#if blockedText}<div class="fw-error" role="alert">{blockedText}</div>{/if}

      {#if oldApps.length}
        <div class="fw-section">
          <p class="fw-note">{$t('farewell.old_app', { path: oldApps.join(', ') })}</p>
          {#if confirmTrash}
            <p class="fw-note">{$t('farewell.trash_confirm')}</p>
            <button class="fw-btn fw-secondary" on:click={() => confirmTrash = false}>{$t('farewell.trash_cancel')}</button>
            <button class="fw-btn fw-secondary" on:click={trashOldApp} disabled={busy}>{$t('farewell.trash_do')}</button>
          {:else}
            <button class="fw-btn fw-secondary" on:click={() => confirmTrash = true} disabled={busy}>{$t('farewell.trash_old_app')}</button>
          {/if}
        </div>
      {/if}

      <div class="fw-footer">
        <button class="fw-link" on:click={keepV1} title={$t('farewell.keep_v1_hint')} disabled={busy}>{$t('farewell.keep_v1')}</button>
        <span class="fw-spacer"></span>
        {#if status?.remnants?.length}
          <button class="fw-btn fw-secondary" on:click={moveNow} disabled={busy}>{$t('farewell.retry_removal')}</button>
        {/if}
        {#if downloadError}
          <button class="fw-btn fw-secondary" on:click={openPage} disabled={busy}>{$t('farewell.open_page')}</button>
        {/if}
        {#if status?.download_ready}
          <button class="fw-btn fw-primary" bind:this={primaryBtn} on:click={openInstaller} disabled={busy}>{$t('farewell.open_installer')}</button>
        {:else}
          <button class="fw-btn fw-primary" bind:this={primaryBtn} on:click={() => download()} disabled={busy}>{$t('farewell.download')}</button>
        {/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .fw-backdrop {
    position: fixed;
    inset: 0;
    background: var(--overlay-bg);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 250;
  }
  .fw-modal {
    background: var(--bg-primary);
    border: 0.5px solid var(--border);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
    padding: var(--space-5) var(--space-6);
    width: 500px;
    max-width: calc(100vw - 40px);
    max-height: calc(100vh - 60px);
    overflow-y: auto;
    color: var(--text-primary);
  }
  .fw-icon {
    width: 56px;
    height: 56px;
    border-radius: 12px;
    display: block;
    margin: 0 0 var(--space-3);
  }
  h2 {
    margin: 0 0 var(--space-2);
    font: var(--text-title-2);
  }
  h3 {
    margin: 0 0 var(--space-2);
    font: var(--text-headline);
  }
  .fw-sub {
    margin: 0 0 var(--space-4);
    font: var(--text-body);
    color: var(--text-secondary);
  }
  .fw-section {
    background: var(--bg-card);
    border: 0.5px solid var(--border);
    border-radius: var(--radius-md);
    padding: var(--space-3) var(--space-4);
    margin-bottom: var(--space-3);
  }
  ul {
    margin: 0 0 var(--space-2);
    padding-left: 18px;
    font: var(--text-body);
  }
  li { margin: 2px 0; }
  .fw-note, .fw-explain {
    margin: 0 0 var(--space-2);
    font: var(--text-footnote);
    color: var(--text-secondary);
  }
  .fw-eol {
    margin: 0 0 var(--space-3);
    font: var(--text-body);
    font-weight: 600;
  }
  .fw-status, .fw-ok, .fw-error {
    display: flex;
    align-items: center;
    gap: 8px;
    margin: var(--space-2) 0;
    padding: var(--space-2) var(--space-3);
    border-radius: var(--radius-sm);
    font: var(--text-body);
  }
  .fw-status { background: var(--bg-card); border: 0.5px solid var(--border); color: var(--text-secondary); }
  .fw-ok { background: var(--bg-card); border: 0.5px solid var(--green); color: var(--text-primary); }
  .fw-error { background: var(--error-bg); border: 0.5px solid var(--red); color: var(--error-text); }
  .fw-spinner {
    width: 10px;
    height: 10px;
    border: 1.5px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: fwspin 0.8s linear infinite;
    flex-shrink: 0;
  }
  @keyframes fwspin { to { transform: rotate(360deg); } }
  .fw-footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: var(--space-2);
    margin-top: var(--space-4);
  }
  .fw-spacer { flex: 1; }
  .fw-btn {
    height: 28px;
    padding: 0 var(--space-4);
    border-radius: var(--radius-btn);
    font: var(--text-headline);
    cursor: pointer;
  }
  .fw-btn:disabled, .fw-link:disabled { opacity: 0.45; cursor: not-allowed; }
  .fw-primary { background: var(--gradient-accent); border: 0; color: var(--text-inverse); }
  .fw-primary:hover:not(:disabled) { filter: brightness(1.1); }
  .fw-secondary { background: var(--bg-card); border: 0.5px solid var(--border); color: var(--text-primary); }
  .fw-secondary:hover:not(:disabled) { background: var(--bg-hover); }
  .fw-link {
    background: none;
    border: 0;
    padding: 0;
    color: var(--accent);
    font: var(--text-footnote);
    cursor: pointer;
  }
</style>
