<script lang="ts">
  import { onMount } from 'svelte';

  export let nodeId: string;
  export let node: any;
  export let title: string;
  export let netType: string;
  export let netTypeDesc: string;
  export let nics: any[];
  export let virtCount: number;
  export let probedHostname: string;
  export let setupBase: string;

  let provider = node.provider || 'bare';
  let editingProvider = false;
  let providerInput: HTMLInputElement;

  let bsRole = '';
  let bsDataDisk = '/data';
  let cinitBody = '';
  let cinitUrl = '';
  let cinitVisible = false;
  let copyOkVisible = false;

  let configBody = '';
  let configStatus = '';

  // ── Takeover state ──
  let toDevice = '/dev/sda';
  let toDeviceCustom = '';
  let toChannel = 'stable';
  let toBody = '';
  let toVisible = false;
  let toCopyOkVisible = false;
  let toGenerating = false;
  let toDeviceOptions: {value:string;label:string}[] = [];

  const os = node.os || {};
  const smbios = node.smbios || {};
  const identity = node.identity || {};

  onMount(() => {
    try {
      const r = localStorage.getItem('cinit_role');
      if (r) bsRole = r;
      const d = localStorage.getItem('cinit_disk');
      if (d) bsDataDisk = d;
      const td = localStorage.getItem('to_device');
      if (td) toDevice = td;
      const tc = localStorage.getItem('to_channel');
      if (tc) toChannel = tc;
    } catch (e) {}
    // Build device options from node disks
    const disks = node.disks || [];
    if (disks.length > 0) {
      toDeviceOptions = disks.map((d: any) => ({
        value: '/dev/' + (d.name || 'unknown'),
        label: '/dev/' + (d.name || 'unknown') + (d.size_bytes ? ' — ' + Math.round(d.size_bytes/1073741824*10)/10 + ' GB' : ''),
      }));
    }
    if (!toDeviceOptions.find(o => o.value === toDevice) && toDevice !== 'custom') {
      toDeviceOptions.push({ value: toDevice, label: toDevice });
    }
    toDeviceOptions.push({ value: 'custom', label: 'Custom path…' });
    // Fetch existing takeover
    fetchTakeover();
  });

  function saveCloudInit() {
    try { localStorage.setItem('cinit_role', bsRole); localStorage.setItem('cinit_disk', bsDataDisk); } catch (e) {}
  }

  async function generateCloudInit() {
    saveCloudInit();
    cinitVisible = true;
    cinitBody = 'Loading...';
    try {
      const resp = await fetch(`${location.origin}/api/v1/cloud-init?node=${nodeId}&role=${bsRole}&data_disk=${encodeURIComponent(bsDataDisk)}`);
      if (resp.ok) {
        cinitBody = await resp.text();
        cinitUrl = `${location.origin}/api/v1/cloud-init?node=${nodeId}&role=${bsRole}&data_disk=${encodeURIComponent(bsDataDisk)}`;
      } else {
        cinitBody = `Error: ${resp.status}`;
      }
    } catch (e: any) {
      cinitBody = `Error: ${e.message}`;
    }
  }

  function copyCloudInit() {
    navigator.clipboard.writeText(cinitBody);
    copyOkVisible = true;
    setTimeout(() => { copyOkVisible = false; }, 2000);
  }

  function downloadCloudInit() {
    const a = document.createElement('a');
    a.href = 'data:text/plain;charset=utf-8,' + encodeURIComponent(cinitBody);
    a.download = `alpine-config-${nodeId.slice(0, 8)}.yaml`;
    a.click();
  }

  async function markReady() {
    try {
      const resp = await fetch(`/api/v1/nodes/${nodeId}/ready`, { method: 'POST' });
      if (!resp.ok) throw new Error(String(resp.status));
      location.reload();
    } catch (e: any) { alert('Failed: ' + e.message); }
  }

  function startEditProvider() {
    editingProvider = true;
    setTimeout(() => providerInput?.focus(), 0);
  }

  async function saveProvider() {
    editingProvider = false;
    provider = (provider || 'bare').trim();
    try {
      const resp = await fetch(`${location.origin}/api/v1/nodes/${nodeId}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ provider })
      });
      if (!resp.ok) throw new Error(resp.status + ' ' + (await resp.text()));
    } catch (e: any) { alert('Failed to save provider: ' + e.message); }
  }

  async function pushConfig() {
    if (!configBody.trim()) { configStatus = '<span class="text-red">Config body required</span>'; return; }
    configStatus = 'Pushing...';
    try {
      const resp = await fetch(`/api/v1/nodes/${nodeId}/config`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ body: configBody })
      });
      const data = await resp.json();
      if (!resp.ok) throw new Error((data && data.error) || String(resp.status));
      configStatus = '<span class="text-green">✓ Config pushed. Node picks it up on next poll.</span>';
    } catch (e: any) {
      configStatus = '<span class="text-red">Error: ' + e.message + '</span>';
    }
  }

  // ── Takeover ──
  function saveTakeoverOpts() {
    try {
      localStorage.setItem('to_device', toDevice === 'custom' ? toDeviceCustom : toDevice);
      localStorage.setItem('to_channel', toChannel);
    } catch (e) {}
  }

  async function fetchTakeover() {
    try {
      const r = await fetch(`${location.origin}/api/v1/nodes/${nodeId}/takeover`);
      if (r.status !== 200) return;
      const data = await r.json();
      if (data.exists && !data.expired && data.command) {
        toBody = data.command;
        toVisible = true;
      }
    } catch (e) {}
  }

  async function generateTakeover() {
    saveTakeoverOpts();
    const device = toDevice === 'custom' ? (toDeviceCustom || '/dev/sda') : toDevice;
    toVisible = true;
    toBody = 'Generating…';
    toGenerating = true;

    try {
      const r = await fetch(`${location.origin}/api/v1/nodes/${nodeId}/takeover`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ device, channel: toChannel }),
      });
      if (!r.ok) {
        const err = await r.json();
        toBody = `Error: ${err.error || r.status}`;
      } else {
        const data = await r.json();
        toBody = data.command;
      }
    } catch (e: any) {
      toBody = `Error: ${e.message}`;
    } finally {
      toGenerating = false;
    }
  }

  function copyTakeover() {
    navigator.clipboard.writeText(toBody);
    toCopyOkVisible = true;
    setTimeout(() => { toCopyOkVisible = false; }, 2000);
  }

  async function revokeTakeover() {
    if (!confirm('Revoke this takeover token? The command will no longer work.')) return;
    try {
      const r = await fetch(`${location.origin}/api/v1/nodes/${nodeId}/takeover`, { method: 'DELETE' });
      if (!r.ok) throw new Error(String(r.status));
      toVisible = false;
      toBody = '';
    } catch (e: any) { alert('Revoke failed: ' + e.message); }
  }

  function toggleTheme() {
    const html = document.documentElement;
    const current = html.getAttribute('data-theme');
    html.setAttribute('data-theme', current === 'dark' ? 'light' : 'dark');
    localStorage.setItem('theme', current === 'dark' ? 'light' : 'dark');
  }
</script>

<div class="content-area">
  <div class="topbar">
    <a href={setupBase} class="back-link">← Back to Setup</a>
    <button class="theme-toggle" on:click={toggleTheme} title="Toggle theme">☀</button>
  </div>

  <div class="node-header">
    <h1>{title}</h1>
    <span class="badge" class:badge-ok={node.state === 'bootstrapped'} class:badge-err={node.state === 'failed'} class:badge-pending={node.state !== 'bootstrapped' && node.state !== 'failed'} style="margin-left:12px;font-size:13px">
      {node.state || 'unknown'}
    </span>
    {#if node.state !== 'bootstrapped'}
      <button class="btn btn-ghost btn-sm" style="margin-left:8px" on:click={markReady}>✓ Mark bootstrapped</button>
    {/if}
  </div>

  <div class="card-stack">
    <!-- System -->
    <div class="card">
      <div class="card-header">System</div>
      <div class="card-body">
        <div class="spec-label">identity</div>
        <dl class="kv-grid">
          <dt>Machine ID</dt><dd class="mono dim xs">{nodeId}</dd>
          <dt>Hostname</dt>
          <dd class="fw500">
            {title}
            {#if probedHostname && probedHostname !== 'localhost'}
              <br/><span class="dim sm mono">{probedHostname}</span>
            {/if}
          </dd>
          <dt>Virt</dt><dd><span class="badge badge-accent">{node.virt || 'bare'}</span></dd>
          {#if identity.cloud_provider && identity.cloud_provider !== 'bare'}
            <dt>Cloud</dt><dd>{identity.cloud_provider}</dd>
          {/if}
          <dt>Provider</dt>
          <dd>
            {#if editingProvider}
              <input
                bind:this={providerInput}
                bind:value={provider}
                class="provider-input"
                on:blur={saveProvider}
                on:keydown={(e) => e.key === 'Enter' && saveProvider()}
              />
            {:else}
              <span class="provider-display" on:click={startEditProvider}>{provider}</span>
            {/if}
          </dd>
        </dl>
        <hr class="spec-divider" />
        <div class="spec-label">os-release</div>
        <dl class="kv-grid">
          <dt>Distribution</dt><dd>{os.pretty || os.name || os.id || '—'}{os.version && !os.pretty ? ' ' + os.version : ''}</dd>
          <dt>Kernel</dt><dd class="mono">{os.kernel || '—'}</dd>
          <dt>Arch</dt><dd class="mono">{node.cpu?.arch || os.arch || '—'}</dd>
          {#if os.codename}
            <dt>Codename</dt><dd>{os.codename}</dd>
          {/if}
          {#if os.id_like}
            <dt>Family</dt><dd>{os.id_like}</dd>
          {/if}
        </dl>
        <hr class="spec-divider" />
        <div class="spec-label">/proc/cpuinfo · /proc/meminfo</div>
        <dl class="kv-grid">
          <dt>CPU</dt><dd>{node.cpu?.model || '?'} · {node.cpu?.cores || '?'} cores{node.cpu?.mhz ? ' @ ' + (Math.round(node.cpu.mhz/100)/10) + ' GHz' : ''}</dd>
          {#if node.cpu?.vendor}
            <dt>Vendor</dt><dd>{node.cpu.vendor}</dd>
          {/if}
          <dt>Memory</dt><dd>{node.memory_mb ? Math.round(node.memory_mb/1024*10)/10 + ' GB' : '—'}</dd>
          <dt>Disk</dt>
          <dd>
            {#if node.disks?.blockdevices?.length > 0 || node.disks?.length > 0}
              {(node.disks?.blockdevices || node.disks || []).map((d: any) => {
                const size = parseInt(d.size, 10);
                return size ? Math.round(size/1e9*10)/10 + ' GB' : '—';
              }).join(', ')}
            {:else}
              —
            {/if}
          </dd>
        </dl>
        {#if smbios.product_serial || smbios.product_name}
          <hr class="spec-divider" />
          <div class="spec-label">smbios</div>
          <dl class="kv-grid">
            <dt>Serial</dt><dd class="mono xs">{smbios.product_serial}</dd>
            <dt>Product</dt><dd>{smbios.product_name || '—'}</dd>
          </dl>
        {/if}
      </div>
    </div>

    <!-- Network -->
    <div class="card">
      <div class="card-header">Network</div>
      <div class="card-body">
        {#if node.public_ip || node.egress_ip}
          <dl class="kv-grid">
            {#if node.public_ip}
              <dt>IPv4</dt><dd class="mono">{node.public_ip} <span class="badge badge-ok" style="font-size:10px">public</span></dd>
            {/if}
            {#if node.public_ip6}
              <dt>IPv6</dt><dd class="mono xs">{node.public_ip6} <span class="badge badge-ok" style="font-size:10px">public</span></dd>
            {/if}
            {#if node.egress_ip && node.egress_ip !== node.public_ip}
              <dt>Egress</dt><dd class="mono">{node.egress_ip}</dd>
            {/if}
            {#if node.geo?.city}
              <dt>Location</dt><dd>{[node.geo.city, node.geo.region, node.geo.country].filter(Boolean).join(', ')}</dd>
            {/if}
            <dt>Net type</dt><dd><span class="badge badge-accent">{netType}</span> <span class="dim sm xs">{netTypeDesc || ''}</span></dd>
          </dl>
        {/if}
        {#if nics.length > 0}
          {#if node.public_ip || node.egress_ip}
            <hr class="spec-divider" />
          {/if}
          <div class="spec-label">interfaces {#if virtCount > 0}<span class="dim">· {virtCount} virtual hidden</span>{/if}</div>
          {#each nics as nic}
            <div class="nic-row">
              <span class="nic-name">{nic.iface || '—'}</span>
              {#each nic.ip4s || [] as ip4}
                <span class="nic-item">v4 <code>{ip4}</code></span>
              {/each}
              {#each nic.ip6s || [] as ip6}
                <span class="nic-item dim">v6 <code class="xs">{ip6}</code></span>
              {/each}
              {#if nic.gateway}
                <span class="nic-item">GW <code>{nic.gateway}</code></span>
              {/if}
              <span class="badge" class:badge-ok={nic.is_up} class:badge-warn={!nic.is_up} style="font-size:10px">{nic.is_up ? 'up' : 'down'}</span>
              {#if nic.is_dhcp}
                <span class="badge badge-accent" style="font-size:10px">DHCP</span>
              {/if}
              {#if nic.scope === 'public'}
                <span class="badge badge-ok" style="font-size:10px">public</span>
              {:else if nic.scope === 'cgnat'}
                <span class="badge badge-warn" style="font-size:10px">CGNAT</span>
              {/if}
            </div>
          {/each}
        {:else}
          <p class="dim sm">No physical interfaces detected</p>
        {/if}
        {#if node.latency && Object.keys(node.latency).length > 0}
          <div class="spec-label">latency (ms)</div>
          {#each Object.entries(node.latency) as [iface, lat]}
            <div class="nic-row">
              <span class="nic-name">{iface}</span>
              {#each Object.entries(lat || {}) as [host, ms]}
                <span class="nic-item"><code>{host}</code> <span class="fw500">{ms}ms</span></span>
              {/each}
            </div>
          {/each}
        {/if}
      </div>
    </div>

    <!-- Cloud-init -->
    <div class="card">
      <div class="card-header"><span>Cloud-init</span> <span class="dim sm">Generate bootstrap config for this node</span></div>
      <div class="card-body">
        <div class="form-row">
          <label class="form-label">Role</label>
          <select bind:value={bsRole} class="form-select" on:change={saveCloudInit}>
            <option value="server">Server</option>
            <option value="server+client">Server + Client</option>
            <option value="client">Client</option>
            <option value="edge">Edge</option>
          </select>
          <label class="form-label" style="margin-left:12px">Data disk</label>
          <input bind:value={bsDataDisk} class="form-input" on:blur={saveCloudInit} style="width:120px" placeholder="/dev/vda" />
          <button class="btn btn-primary btn-sm" style="margin-left:12px" on:click={generateCloudInit}>Generate</button>
        </div>
        {#if cinitVisible}
          <div class="mt">
            <div class="form-actions">
              <button class="btn btn-ghost btn-sm" on:click={copyCloudInit}>📋 Copy</button>
              <button class="btn btn-ghost btn-sm" on:click={downloadCloudInit}>💾 Download</button>
              <span id="copyOk" class="text-green sm ml" class:hidden={!copyOkVisible}>Copied!</span>
            </div>
            <pre class="code-block mt" style="max-height:400px">{cinitBody}</pre>
          </div>
        {/if}
      </div>
    </div>

    <!-- Takeover -->
    <div class="card">
      <div class="card-header"><span>Full-Disk Takeover</span> <span class="dim sm">Install kairos-alpine to bare disk</span></div>
      <div class="card-body">
        <p class="dim sm">Run on the target machine in <strong>rescue mode</strong>. <strong>Wipes all data on the target device.</strong></p>
        <div class="form-row">
          <label class="form-label">Device</label>
          <select bind:value={toDevice} class="form-select" on:change={saveTakeoverOpts}>
            {#each toDeviceOptions as opt}
              <option value={opt.value}>{opt.label}</option>
            {/each}
          </select>
          {#if toDevice === 'custom'}
            <input bind:value={toDeviceCustom} class="form-input" style="width:160px;margin-left:8px" placeholder="/dev/nvme0n1" on:blur={saveTakeoverOpts} />
          {/if}
          <label class="form-label" style="margin-left:12px">Channel</label>
          <select bind:value={toChannel} class="form-select" on:change={saveTakeoverOpts}>
            <option value="stable">stable</option>
            <option value="edge">edge</option>
          </select>
          <button class="btn btn-primary btn-sm" style="margin-left:12px" on:click={generateTakeover} disabled={toGenerating}>Generate</button>
        </div>
        {#if toVisible}
          <div class="mt">
            <div class="form-actions">
              <button class="btn btn-ghost btn-sm" on:click={copyTakeover}>📋 Copy</button>
              <span class="text-green sm ml" class:hidden={!toCopyOkVisible}>Copied!</span>
              <button class="btn btn-ghost btn-sm" style="margin-left:auto;color:var(--t-red)" on:click={revokeTakeover}>Revoke</button>
            </div>
            <pre class="code-block mt" style="max-height:200px;white-space:pre-wrap;word-break:break-all">{toBody}</pre>
          </div>
        {/if}
      </div>
    </div>

    <!-- Config Push -->
    <div class="card">
      <div class="card-header"><span>Config Push</span></div>
      <div class="card-body">
        <p class="dim sm">Push a YAML config to the node's pending-config queue. The node picks it up on next poll.</p>
        <textarea bind:value={configBody} class="form-textarea" spellcheck="false" rows="6" placeholder={`#cloud-config
stages:
  boot:
    - name: apply
      commands:
        - echo done`}></textarea>
        <div class="form-actions mt">
          <button class="btn btn-primary btn-sm" on:click={pushConfig}>Push Config</button>
        </div>
        {#if configStatus}
          <div class="mt sm">{@html configStatus}</div>
        {/if}
      </div>
    </div>
  </div>
</div>
