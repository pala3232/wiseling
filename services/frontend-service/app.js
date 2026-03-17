const { createApp, ref, reactive, computed, onMounted, onUnmounted, watch } = Vue;

// ── CONSTANTS ──────────────────────────────────────────────────────────────
const API_BASE = window.API_BASE || '';
const WALLET_CLS = { BTC:'btc', ETH:'eth', USD:'usd', EUR:'eur', GBP:'gbp' };
const CUR_SYM = { USD:'$', EUR:'€', GBP:'£', BTC:'₿', ETH:'Ξ' };
const PAGE_NAMES = { overview:'Overview', wallets:'My Wallets', convert:'Convert', withdraw:'Send Money', history:'Transactions' };

// ── HELPERS ─────────────────────────────────────────────────────────────────
function genUID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

function fmtAmount(amount, currency) {
  const sym = CUR_SYM[currency] || '';
  const val = parseFloat(amount || 0);
  const decimals = ['BTC','ETH'].includes(currency) ? 8 : 2;
  return sym + val.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: decimals });
}

function fmtDate(dateStr) {
  if (!dateStr) return '—';
  return new Date(dateStr).toLocaleDateString('en-GB', { day:'2-digit', month:'short', year:'numeric' });
}

// ── VUE APP ──────────────────────────────────────────────────────────────────
createApp({
  setup() {
    // ── AUTH STATE ──
    const token = ref(localStorage.getItem('wsl_token'));
    const userEmail = ref(localStorage.getItem('wsl_email'));
    const authTab = ref('login');
    const authEmail = ref('');
    const authPassword = ref('');
    const authLoading = ref(false);
    const authError = ref('');

    // ── APP STATE ──
    const currentPage = ref('overview');
    const ratesCache = ref({});
    const wallets = ref([]);
    const allConversions = ref([]);
    const allWithdrawals = ref([]);
    const allTransfers = ref([]);
    const myAccountNumber = ref('');
    const overviewLoading = ref(true);
    const walletsLoading = ref(false);
    const historyLoading = ref(false);
    const historyFilter = ref('all');
    const recentRecipients = ref(JSON.parse(localStorage.getItem('wsl_recipients') || '[]'));
    const pendingWithdrawals = ref([]);
    let pollInterval = null;
    let sseSource = null;
    const sseConnected = ref(false);

    // ── CONVERT STATE ──
    const convFrom = ref('USD');
    const convTo = ref('EUR');
    const convAmount = ref('');
    const convLoading = ref(false);
    const convError = ref('');
    const convResult = ref(null);

    // ── WITHDRAW STATE ──
    const wdAccountNumber = ref('');
    const wdCurrency = ref('USD');
    const wdAmount = ref('');
    const wdLoading = ref(false);
    const wdError = ref('');
    const wdResult = ref(null);
    const wdRecipient = ref(null);
    const wdRecipientLoading = ref(false);
    const showConfirmModal = ref(false);
    const confirmLoading = ref(false);

    // ── TOASTS ──
    const toasts = ref([]);

    // ── ENV INFO ──
    const envInfo = ref({ pod_name: "unreachable", node_name: "unreachable", cluster_name: "unreachable", aws_region: "unreachable", aws_az: "unreachable" });
    onMounted(async () => {
      if (token.value) enterDashboard();
      try {
        const res = await fetch('/api/v1/envinfo');
        if (res.ok) {
          const data = await res.json();
          envInfo.value = {
            pod_name: data.pod_name ?? "unknown",
            node_name: data.node_name ?? "unknown",
            cluster_name: data.cluster_name ?? "unknown",
            aws_region: data.aws_region ?? "unknown",
            aws_az: data.aws_az ?? "unknown"
          };
        }
      } catch {}
    });

    // ── COMPUTED ──
    const isLoggedIn = computed(() => !!token.value);

    const totalBalance = computed(() => {
      let total = 0;
      wallets.value.forEach(w => {
        if (w.currency === 'USD') total += parseFloat(w.balance || 0);
        else if (w.currency === 'EUR') total += parseFloat(w.balance || 0) * (ratesCache.value['EUR/USD'] || 1.08);
        else if (w.currency === 'GBP') total += parseFloat(w.balance || 0) * (ratesCache.value['GBP/USD'] || 1.27);
      });
      return '$' + total.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    });

    const currentRate = computed(() => {
      if (!convFrom.value || !convTo.value) return null;
      return ratesCache.value[`${convFrom.value}/${convTo.value}`];
    });

    const currentRateText = computed(() => {
      if (!currentRate.value) return 'Rate unavailable for this pair';
      return `Live rate: 1 ${convFrom.value} = ${parseFloat(currentRate.value).toLocaleString('en-US', { maximumFractionDigits: 6 })} ${convTo.value}`;
    });

    const convPreview = computed(() => {
      if (!currentRate.value || !convAmount.value) return null;
      const received = parseFloat(convAmount.value) * parseFloat(currentRate.value) * 0.997;
      return `≈ ${fmtAmount(received, convTo.value)} ${convTo.value} after 0.30% fee`;
    });

    const fromWalletBalance = computed(() => {
      const w = wallets.value.find(w => w.currency === convFrom.value);
      return w ? fmtAmount(w.balance, convFrom.value) + ' ' + convFrom.value : null;
    });

    const wdWalletBalance = computed(() => {
      const w = wallets.value.find(w => w.currency === wdCurrency.value);
      return w ? fmtAmount(w.balance, wdCurrency.value) + ' ' + wdCurrency.value : null;
    });

    const filteredHistory = computed(() => {
      let rows = [];
      if (historyFilter.value === 'all' || historyFilter.value === 'conversions')
        rows.push(...allConversions.value.map(x => ({ ...x, _type: 'conversion' })));
      if (historyFilter.value === 'all' || historyFilter.value === 'withdrawals')
        rows.push(...allWithdrawals.value.map(x => ({ ...x, _type: 'withdrawal' })));
      if (historyFilter.value === 'all' || historyFilter.value === 'transfers')
        rows.push(...allTransfers.value.map(x => ({ ...x, _type: 'transfer' })));
      return rows.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    });

    const recentActivity = computed(() => {
      const items = [
        ...allConversions.value.slice(-5).map(c => ({ ...c, _type: 'conversion' })),
        ...allWithdrawals.value.slice(-5).map(w => ({ ...w, _type: 'withdrawal' })),
        ...allTransfers.value.slice(-5).map(t => ({ ...t, _type: 'transfer' })),
      ].sort((a, b) => new Date(b.created_at) - new Date(a.created_at)).slice(0, 6);
      return items;
    });

    const greeting = computed(() => {
      const h = new Date().getHours();
      return h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
    });

    // ── API ──
    async function api(method, path, body, formEncoded = false) {
      const headers = {};
      if (token.value) headers['Authorization'] = `Bearer ${token.value}`;
      let bodyStr;
      if (body) {
        if (formEncoded) { headers['Content-Type'] = 'application/x-www-form-urlencoded'; bodyStr = new URLSearchParams(body).toString(); }
        else { headers['Content-Type'] = 'application/json'; bodyStr = JSON.stringify(body); }
      }
      const res = await fetch(API_BASE + path, { method, headers, body: bodyStr });
      if (res.status === 401) { logout(); throw new Error('Session expired. Please sign in again.'); }
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.detail || `Error ${res.status}`);
      return data;
    }

    // ── TOASTS ──
    function showToast(msg, type = 'success') {
      const id = genUID();
      toasts.value.push({ id, msg, type });
      setTimeout(() => { toasts.value = toasts.value.filter(t => t.id !== id); }, 3500);
    }

    // ── AUTH ──
    async function handleAuth() {
      authError.value = '';
      authLoading.value = true;
      try {
        if (authTab.value === 'register') {
          await api('POST', '/api/v1/auth/register', { email: authEmail.value, password: authPassword.value });
          showToast('Account created. Please sign in.', 'success');
          authTab.value = 'login';
          authLoading.value = false;
          return;
        }
        const data = await api('POST', '/api/v1/auth/login', { username: authEmail.value, password: authPassword.value }, true);
        token.value = data.access_token;
        localStorage.setItem('wsl_token', data.access_token);
        localStorage.setItem('wsl_email', authEmail.value);
        userEmail.value = authEmail.value;
        enterDashboard();
      } catch (err) {
        authError.value = err.message;
      }
      authLoading.value = false;
    }

    function logout() {
      token.value = null;
      userEmail.value = null;
      localStorage.removeItem('wsl_token');
      localStorage.removeItem('wsl_email');
      stopSSE();
      stopPolling();
    }

    // ── DASHBOARD INIT ──
    async function enterDashboard() {
      await loadRates();
      await loadOverview();
      loadMyAccountNumber();
      startPolling();
    }

    async function loadMyAccountNumber() {
      try {
        const me = await api('GET', '/api/v1/auth/me');
        if (me.account_number) myAccountNumber.value = me.account_number;
      } catch (e) {}
    }

    // ── NAVIGATION ──
    function navigate(page) {
      currentPage.value = page;
      if (page === 'wallets') loadWallets();
      if (page === 'history') loadHistory();
    }

    // ── RATES ──
    async function loadRates() {
      try {
        ratesCache.value = await api('GET', '/api/v1/conversions/rates');
      } catch {}
    }

    // ── OVERVIEW ──
    async function loadOverview() {
      overviewLoading.value = true;
      try {
        const [ws, convs, wds, transfers] = await Promise.all([
          api('GET', '/api/v1/wallet/balances'),
          api('GET', '/api/v1/conversions'),
          api('GET', '/api/v1/withdrawals'),
          api('GET', '/api/v1/wallet/transfers'),
        ]);
        wallets.value = Array.isArray(ws) ? ws : [];
        allConversions.value = Array.isArray(convs) ? convs : [];
        allWithdrawals.value = Array.isArray(wds) ? wds : [];
        allTransfers.value = Array.isArray(transfers) ? transfers : [];

        // Track pending withdrawals for polling
        pendingWithdrawals.value = allWithdrawals.value.filter(w => ['pending', 'processing'].includes((w.status || '').toLowerCase()));
      } catch (e) {
        showToast(e.message, 'error');
      }
      overviewLoading.value = false;
    }

    // ── WALLETS ──
    async function loadWallets() {
      walletsLoading.value = true;
      try {
        const ws = await api('GET', '/api/v1/wallet/balances');
        wallets.value = Array.isArray(ws) ? ws : [];
      } catch (e) { showToast(e.message, 'error'); }
      walletsLoading.value = false;
    }

    async function copyWalletId(id) {
      await navigator.clipboard.writeText(id);
      showToast('Wallet ID copied', 'success');
    }

    // ── CONVERT ──
    async function handleConvert() {
      convError.value = '';
      convResult.value = null;
      convLoading.value = true;
      try {
        const res = await api('POST', '/api/v1/conversions', {
          from_currency: convFrom.value,
          to_currency: convTo.value,
          amount: parseFloat(convAmount.value),
          idempotency_key: genUID(),
        });
        convResult.value = res;
        convAmount.value = '';
        showToast('Conversion successful', 'success');
        // Refresh wallets inline — no need to navigate away
        await loadWallets();
        await loadOverview();
      } catch (err) {
        convError.value = err.message;
      }
      convLoading.value = false;
    }

    // ── RECIPIENT LOOKUP ──
    let lookupTimeout = null;
    function onAccountInput() {
      wdRecipient.value = null;
      const raw = wdAccountNumber.value.replace(/\D/g, '').slice(0, 12);
      let formatted = raw;
      if (raw.length > 8) formatted = raw.slice(0,4)+'-'+raw.slice(4,8)+'-'+raw.slice(8);
      else if (raw.length > 4) formatted = raw.slice(0,4)+'-'+raw.slice(4);
      wdAccountNumber.value = formatted;
      if (formatted.length === 14) {
        clearTimeout(lookupTimeout);
        lookupTimeout = setTimeout(() => lookupRecipient(formatted), 300);
      }
    }

    async function lookupRecipient(accountNumber) {
      wdRecipientLoading.value = true;
      try {
        const res = await api('GET', `/api/v1/wallet/lookup/${accountNumber}`);
        wdRecipient.value = { email: res.email, found: true };
      } catch {
        wdRecipient.value = { found: false };
      }
      wdRecipientLoading.value = false;
    }

    // ── SEND MONEY (with confirm modal) ──
    function initiateWithdraw() {
      if (!wdRecipient.value?.found) return;
      showConfirmModal.value = true;
    }

    async function confirmWithdraw() {
      confirmLoading.value = true;
      wdError.value = '';
      try {
        const res = await api('POST', '/api/v1/withdrawals/transfer', {
          to_account_number: wdAccountNumber.value,
          currency: wdCurrency.value,
          amount: parseFloat(wdAmount.value),
          idempotency_key: genUID(),
        });
        wdResult.value = res;
        showConfirmModal.value = false;

        // Save recent recipient
        if (wdRecipient.value?.email) {
          addRecentRecipient(wdRecipient.value.email, wdAccountNumber.value);
        }

        showToast('Transfer sent!', 'success');
        wdAmount.value = '';
        wdAccountNumber.value = '';
        wdRecipient.value = null;

        // Refresh wallets inline
        await loadWallets();
        await loadOverview();

        // Poll if pending
        if (res.status === 'pending' || res.status === 'processing') {
          pendingWithdrawals.value.push(res);
        }
      } catch (err) {
        wdError.value = err.message;
        showConfirmModal.value = false;
        showToast(err.message, 'error');
      }
      confirmLoading.value = false;
    }

    // ── RECENT RECIPIENTS ──
    function addRecentRecipient(email, accountNumber) {
      recentRecipients.value = recentRecipients.value.filter(r => r.accountNumber !== accountNumber);
      recentRecipients.value.unshift({ email, accountNumber });
      recentRecipients.value = recentRecipients.value.slice(0, 5);
      localStorage.setItem('wsl_recipients', JSON.stringify(recentRecipients.value));
    }

    function fillRecipient(accountNumber, email) {
      wdAccountNumber.value = accountNumber;
      wdRecipient.value = { email, found: true };
    }

    // ── HISTORY ──
    async function loadHistory() {
      historyLoading.value = true;
      try {
        const [convs, wds, transfers] = await Promise.all([
          api('GET', '/api/v1/conversions'),
          api('GET', '/api/v1/withdrawals'),
          api('GET', '/api/v1/wallet/transfers'),
        ]);
        allConversions.value = Array.isArray(convs) ? convs : [];
        allWithdrawals.value = Array.isArray(wds) ? wds : [];
        allTransfers.value = Array.isArray(transfers) ? transfers : [];
      } catch (e) { showToast(e.message, 'error'); }
      historyLoading.value = false;
    }

    // ── COPY ACCOUNT NUMBER ──
    async function copyAccountNumber() {
      if (myAccountNumber.value && myAccountNumber.value !== '—') {
        await navigator.clipboard.writeText(myAccountNumber.value);
        showToast('Account number copied', 'success');
      }
    }

    // ── POLLING for pending withdrawals + conversions ──
    let refreshTick = 0;
    function startPolling() {
      pollInterval = setInterval(async () => {
        refreshTick++;
        const hasPendingWds   = pendingWithdrawals.value.length > 0;
        const hasPendingConvs = pendingConversions.value.length > 0;
        const doFullRefresh   = refreshTick % 6 === 0; // every 30s regardless of pending state

        try {
          if (hasPendingWds || doFullRefresh) {
            const [wds, recvWds] = await Promise.all([
              api('GET', '/api/v1/withdrawals'),
              api('GET', '/api/v1/withdrawals/received').catch(() => []),
            ]);
            const sentWds    = Array.isArray(wds)     ? wds.map(w => ({ ...w, direction: 'out' })) : [];
            const inboundWds = Array.isArray(recvWds) ? recvWds.map(w => ({ ...w, direction: 'in' })) : [];
            const freshAll   = [...sentWds, ...inboundWds].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
            let anyUpdated = false;
            if (hasPendingWds) {
              pendingWithdrawals.value = pendingWithdrawals.value.filter(pw => {
                const updated = freshAll.find(w => w.id === pw.id);
                if (updated && !['pending', 'processing'].includes((updated.status || '').toLowerCase())) {
                  const st = (updated.status || '').toLowerCase();
                  showToast(`Transfer ${st}: ${pw.amount} ${pw.currency}`, st === 'completed' ? 'success' : 'error');
                  anyUpdated = true;
                  return false;
                }
                return true;
              });
            }
            if (anyUpdated || doFullRefresh) {
              allWithdrawals.value = freshAll;
              if (anyUpdated) await loadWallets();
            }
            // reseed from ALL withdrawals (sent + received)
            pendingWithdrawals.value = freshAll.filter(w => ['pending', 'processing'].includes((w.status || '').toLowerCase()));
          }

          if (hasPendingConvs || doFullRefresh) {
            const convs = await api('GET', '/api/v1/conversions');
            const fresh = Array.isArray(convs) ? convs : [];
            let anyUpdated = false;
            if (hasPendingConvs) {
              pendingConversions.value = pendingConversions.value.filter(pc => {
                const updated = fresh.find(c => c.id === pc.id);
                if (updated && !['pending', 'processing'].includes((updated.status || '').toLowerCase())) {
                  const st = (updated.status || '').toLowerCase();
                  showToast(`Conversion ${st}: ${pc.from_amount} ${pc.from_currency} → ${pc.to_currency}`, st === 'completed' ? 'success' : 'error');
                  anyUpdated = true;
                  return false;
                }
                return true;
              });
            }
            if (anyUpdated || doFullRefresh) {
              allConversions.value = fresh;
              if (anyUpdated) await loadWallets();
            }
            pendingConversions.value = fresh.filter(c => ['pending', 'processing'].includes((c.status || '').toLowerCase()));
          }
        } catch {}
      }, 5000);
    }

    function stopPolling() {
      if (pollInterval) { clearInterval(pollInterval); pollInterval = null; }
    }

    // ── SSE (optional — connect if backend supports it) ──
    function startSSE() {
      if (!token.value) return;
      try {
        sseSource = new EventSource(`${API_BASE}/api/v1/events?token=${token.value}`);
        sseSource.onopen = () => { sseConnected.value = true; };
        sseSource.onerror = () => { sseConnected.value = false; };
        sseSource.addEventListener('balance_update', async () => { await loadWallets(); });
        sseSource.addEventListener('withdrawal_update', async (e) => {
          const data = JSON.parse(e.data);
          showToast(`Withdrawal ${data.status}`, data.status === 'completed' ? 'success' : 'error');
          await loadOverview();
        });
      } catch {}
    }

    function stopSSE() {
      if (sseSource) { sseSource.close(); sseSource = null; sseConnected.value = false; }
    }

    // ── LIFECYCLE ──
    onMounted(() => {
      if (token.value) enterDashboard();
    });

    onUnmounted(() => {
      stopPolling();
      stopSSE();
    });

    // ── TEMPLATE HELPERS ──
    function walletClass(currency) { return WALLET_CLS[currency] || 'usd'; }
    function curSym(currency) { return CUR_SYM[currency] || ''; }
    function fmt(amount, currency) { return fmtAmount(amount, currency); }
    function date(str) { return fmtDate(str); }

    function txStatusClass(status) {
      const map = { completed:'badge-success', pending:'badge-pending', failed:'badge-failed', processing:'badge-processing' };
      return map[status] || 'badge-pending';
    }

    function txStatusLabel(status) {
      return status ? status.charAt(0).toUpperCase() + status.slice(1) : 'Pending';
    }

    // Env info bar: detect wrapping
    const envInfoBoxRef = ref(null);
    const envInfoIsWrapped = ref(false);
    onMounted(() => {
      // ...existing code...
      // Watch for env info bar wrapping
      const checkWrap = () => {
        const el = envInfoBoxRef.value;
        if (!el) return;
        // If height is more than 1.5x lineHeight, it's wrapped
        const lineHeight = parseFloat(getComputedStyle(el).lineHeight);
        envInfoIsWrapped.value = el.offsetHeight > lineHeight * 1.5;
      };
      window.addEventListener('resize', checkWrap);
      setTimeout(checkWrap, 100);
    });
    onUnmounted(() => {
      window.removeEventListener('resize', () => {});
    });

    return {
      // auth
      token, userEmail, authTab, authEmail, authPassword, authLoading, authError,
      handleAuth, logout,
      // nav
      currentPage, navigate, PAGE_NAMES,
      // rates
      ratesCache, currentRate, currentRateText,
      // overview
      overviewLoading, totalBalance, recentActivity, greeting,
      allConversions, allWithdrawals, allTransfers,
      // wallets
      wallets, walletsLoading, loadWallets, copyWalletId, walletClass, curSym, fmt,
      // convert
      convFrom, convTo, convAmount, convLoading, convError, convResult, convPreview, fromWalletBalance, handleConvert,
      // withdraw
      wdAccountNumber, wdCurrency, wdAmount, wdLoading, wdError, wdResult,
      wdRecipient, wdRecipientLoading, onAccountInput, myAccountNumber, copyAccountNumber,
      wdWalletBalance, initiateWithdraw, confirmWithdraw, showConfirmModal, confirmLoading,
      recentRecipients, fillRecipient,
      // history
      historyFilter, historyLoading, filteredHistory, loadHistory,
      // utils
      toasts, sseConnected, date, txStatusClass, txStatusLabel, fmtAmount,
      isLoggedIn,
      envInfo,
      envInfoBoxRef,
      envInfoIsWrapped,
    };
  },

  template: `
<div id="app">

  <!-- ══ TOASTS ══ -->
  <div style="position:fixed;bottom:1.5rem;right:1.5rem;z-index:9999;display:flex;flex-direction:column;gap:0.5rem;">
    <div v-for="t in toasts" :key="t.id" :class="['toast','toast-'+t.type]">{{ t.msg }}</div>
  </div>

  <!-- ══ CONFIRM MODAL ══ -->
  <div v-if="showConfirmModal" class="modal-overlay" @click.self="showConfirmModal=false">
    <div class="modal">
      <div class="modal-title">Confirm Transfer</div>
      <div class="modal-sub">Please review the details before sending. This action cannot be undone.</div>
      <div class="modal-detail">
        <div class="modal-row"><span class="modal-row-label">To</span><span class="modal-row-val">{{ wdRecipient?.email }}</span></div>
        <div class="modal-row"><span class="modal-row-label">Account</span><span class="modal-row-val" style="font-family:var(--mono)">{{ wdAccountNumber }}</span></div>
        <div class="modal-row"><span class="modal-row-label">Amount</span><span class="modal-row-val" style="color:var(--primary)">{{ wdAmount }} {{ wdCurrency }}</span></div>
        <div class="modal-row"><span class="modal-row-label">Fee</span><span class="modal-row-val">Free</span></div>
      </div>
      <div class="modal-actions">
        <button class="modal-cancel" @click="showConfirmModal=false">Cancel</button>
        <button class="btn-primary" @click="confirmWithdraw" :disabled="confirmLoading">
          {{ confirmLoading ? 'Sending...' : 'Confirm & Send' }}
        </button>
      </div>
    </div>
  </div>

  <!-- ══ AUTH SCREEN ══ -->
  <div id="auth-screen" :class="{visible: !isLoggedIn}">
    <!-- Top bar -->
    <div style="background:var(--bg2);border-bottom:1px solid var(--border);height:56px;display:flex;align-items:center;padding:0 2rem;justify-content:space-between;">
      <div style="display:flex;align-items:center;gap:8px;">
        <div class="auth-logo-box">W</div>
        <div class="auth-logo-text">Wiseling</div>
      </div>
      <div class="auth-topbar-register mobile-only" style="display:flex;align-items:center;gap:1.5rem;">
        <button @click="authTab='register'" style="background:transparent;border:1px solid var(--border2);color:var(--ink);font-family:var(--font);font-size:0.82rem;padding:0.4rem 1rem;border-radius:var(--radius);cursor:pointer;">Register</button>
      </div>
    </div>
    <div class="banner-row">
      <span style="color:var(--primary);flex-shrink:0;">ⓘ</span>
      When sending money, we now verify recipient account numbers in real-time before any transfer is processed.
    </div>
    <div class="auth-body">
      <div class="auth-left">
        <div>
          <div class="auth-left-tag">Convert & Pay</div>
          <h1>Simple, secure<br><span>international banking.</span></h1>
          <p>Manage multiple currencies, convert funds at live rates, send money between your wallets — all from one account.</p>
          <div class="auth-features">
            <div class="auth-feature"><div class="auth-feature-dot"></div>Multi-currency wallets (USD, EUR, GBP and more)</div>
            <div class="auth-feature"><div class="auth-feature-dot"></div>Real-time FX conversions at competitive rates</div>
            <div class="auth-feature"><div class="auth-feature-dot"></div>Account-to-account transfers</div>
            <div class="auth-feature"><div class="auth-feature-dot"></div>Full transaction history</div>
          </div>
        </div>
      </div>
      <div class="auth-right">
        <div class="auth-form-wrap">
          <div class="auth-form-title">{{ authTab === 'login' ? 'Welcome' : 'Create your account' }}</div>
          <div class="tab-switcher">
            <button class="tab-btn" :class="{active:authTab==='login'}" @click="authTab='login'">Sign In</button>
            <button class="tab-btn desktop-only" :class="{active:authTab==='register'}" @click="authTab='register'">Register</button>
          </div>
          <form @submit.prevent="handleAuth">
            <div class="form-group"><label class="form-label">Email Address</label><input class="form-input" type="email" v-model="authEmail" placeholder="you@example.com" required autocomplete="email" /></div>
            <div class="form-group"><label class="form-label">Password</label><input class="form-input" type="password" v-model="authPassword" placeholder="••••••••" required autocomplete="current-password" /></div>
            <div v-if="authTab === 'login'" style="font-size:0.82rem;color:var(--ink-soft);margin-bottom:0.7rem;line-height:1.5;">
              By logging in, you agree to our platform’s <a href="#" style="color:var(--primary);text-decoration:underline;">Terms</a> and <a href="#" style="color:var(--primary);text-decoration:underline;">Privacy Policy</a>.
            </div>
            <div v-if="authTab === 'login'" style="background:var(--surface);border:1px solid var(--primary-dim);border-radius:var(--radius);padding:0.85rem 1rem;font-size:0.83rem;color:var(--ink-mid);margin-bottom:1.1rem;line-height:1.6;">
              <div style="display:flex;align-items:center;gap:8px;margin-bottom:0.3rem;"><span style="color:var(--primary);font-size:1.1em;">&#9432;</span><strong>New: Money Conversion Feature</strong></div>
              We’ve introduced a new money conversion feature for your convenience. Instantly convert between supported currencies within your account.<br>
              All conversions are processed securely and include a flat fee of <strong>0.30%</strong> per transaction.<br>
              For more details, please review our <a href="#" style="color:var(--primary);text-decoration:underline;">Terms</a> or contact support.
            </div>
            <button class="btn-primary" type="submit" :disabled="authLoading">
              <template v-if="authLoading">
                Please wait...
              </template>
              <template v-else-if="authTab === 'login'">
                <span style="display: inline-flex; align-items: center; gap: 0.45em;">
                  <span>Sign In</span>
                  <svg width="18" height="18" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg" style="display:block;">
                    <rect x="4" y="9" width="12" height="7" rx="2" fill="currentColor" fill-opacity="0.18"/>
                    <rect x="4" y="9" width="12" height="7" rx="2" stroke="currentColor" stroke-width="1.5"/>
                    <path d="M7 9V7.5C7 5.567 8.567 4 10.5 4C12.433 4 14 5.567 14 7.5V9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
                    <circle cx="10" cy="12.5" r="1" fill="currentColor"/>
                  </svg>
                </span>
              </template>
              <template v-else>
                Create Account
              </template>
            </button>
            <div v-if="authError" class="error-msg show">{{ authError }}</div>
          </form>
        </div>
        <!-- Env info bar: direct child of .auth-right, after .auth-form-wrap -->
        <div v-if="envInfo && authTab === 'login'" class="env-info-box env-info-authcard">
          Pod: {{ envInfo.pod_name }}
          <span style="padding:0 0.5em;">&bull;</span>
          Node: {{ envInfo.node_name }}
          <span style="padding:0 0.5em;">&bull;</span>
          Cluster: {{ envInfo.cluster_name }}
          <template v-if="envInfo.aws_region && envInfo.aws_region !== 'unknown' && envInfo.aws_az && envInfo.aws_az !== 'unknown'">
            <span style="padding:0 0.5em;">&bull;</span> <span style="white-space:nowrap">Region: {{ envInfo.aws_region }}{{ envInfo.aws_az }}</span>
          </template>
          <template v-else-if="envInfo.aws_region && envInfo.aws_region !== 'unknown'">
            <span style="padding:0 0.5em;">&bull;</span> <span style="white-space:nowrap">Region: {{ envInfo.aws_region }}</span>
          </template>
          <template v-else-if="envInfo.aws_az && envInfo.aws_az !== 'unknown'">
            <span style="padding:0 0.5em;">&bull;</span> <span style="white-space:nowrap">AZ: {{ envInfo.aws_az }}</span>
          </template>
        </div>
        </div>
      </div>
    </div>
  </div>

<!-- ══ DASHBOARD ══ -->
  <div id="dashboard-screen" :class="{visible: isLoggedIn}">
    <header class="topbar">
      <div class="topbar-row">
        <div class="topbar-logo"><div class="topbar-logo-box">W</div><div class="topbar-logo-text">Wiseling</div></div>
        <nav class="topbar-nav">
          <button v-for="(label, key) in PAGE_NAMES" :key="key" class="topbar-nav-item" :class="{active:currentPage===key}" @click="navigate(key)">{{ label }}</button>
        </nav>
        <div class="topbar-right">
          <div class="rates-row">
            <div class="rate-item"><span class="rate-pair">EUR/USD</span><span class="rate-val">{{ ratesCache['EUR/USD'] ? parseFloat(ratesCache['EUR/USD']).toFixed(4) : '—' }}</span></div>
            <div class="rate-item"><span class="rate-pair">GBP/USD</span><span class="rate-val">{{ ratesCache['GBP/USD'] ? parseFloat(ratesCache['GBP/USD']).toFixed(4) : '—' }}</span></div>
          </div>
          <div class="user-area">
            <div class="user-avatar">{{ userEmail ? userEmail[0].toUpperCase() : '?' }}</div>
            <span class="user-email-short">{{ userEmail }}</span>
            <button class="logout-link" @click="logout">Sign out</button>
          </div>
        </div>
      </div>
      <!-- Banner row -->
      <div class="banner-row">
        <span style="color:var(--primary);flex-shrink:0;">ⓘ</span>
        When sending money, we now verify recipient account numbers in real-time before any transfer is processed.
      </div>
    </header>


    <div class="subnav">

    <div class="subnav">
      <span class="subnav-home" @click="navigate('overview')">Home</span>
      <span class="subnav-sep">›</span>
      <span class="subnav-current">{{ PAGE_NAMES[currentPage] }}</span>
    </div>

    <div class="main-content">

      <!-- ── OVERVIEW ── -->
      <div class="page" :class="{active:currentPage==='overview'}">
        <div class="page-header">
          <div><div class="page-title">{{ greeting }}</div><div class="page-sub">Account overview</div></div>
        </div>
        <div v-if="overviewLoading" class="loading"><div class="spinner"></div>Loading...</div>
        <template v-else>
          <div class="balance-hero">
            <div class="balance-hero-label">Total Portfolio Value</div>
            <div class="balance-hero-amount">{{ totalBalance }}</div>
            <div class="balance-hero-sub">USD equivalent across all wallets</div>
            <div class="balance-hero-stats">
              <div><div class="bhs-val">{{ allConversions.length }}</div><div class="bhs-label">Conversions</div></div>
              <div><div class="bhs-val">{{ allWithdrawals.length }}</div><div class="bhs-label">Withdrawals</div></div>
              <div><div class="bhs-val">{{ wallets.length }}</div><div class="bhs-label">Active Wallets</div></div>
            </div>
          </div>
          <div class="quick-actions">
            <button class="qa-btn" @click="navigate('convert')"><div class="qa-icon">⇄</div><div><div class="qa-text-label">Convert Currency</div><div class="qa-text-desc">Exchange between wallets</div></div></button>
            <button class="qa-btn" @click="navigate('withdraw')"><div class="qa-icon">↑</div><div><div class="qa-text-label">Send Money</div><div class="qa-text-desc">Transfer to Wiseling user</div></div></button>
            <button class="qa-btn" @click="navigate('wallets')"><div class="qa-icon">◎</div><div><div class="qa-text-label">View Wallets</div><div class="qa-text-desc">Check all balances</div></div></button>
          </div>
          <div class="table-card">
            <div class="table-header"><div class="table-title">Recent Transactions</div><button class="btn-sm btn-outline" @click="navigate('history')">View all</button></div>
            <div v-if="!recentActivity.length" class="empty-state">
              <div class="empty-state-icon">◎</div>
              No transactions yet
              <div class="empty-state-hint">Convert or send money to get started</div>
            </div>
            <table v-else>
              <thead><tr><th>Type</th><th>Details</th><th>Amount</th><th>Status</th></tr></thead>
              <tbody>
                <tr v-for="item in recentActivity" :key="item.id">
                  <td>
                    <span v-if="item._type==='conversion'" class="badge badge-type">Conversion</span>
                    <span v-else-if="item._type==='transfer'" class="badge badge-type" style="background:rgba(139,92,246,0.15);color:#a78bfa;">Transfer</span>
                    <span v-else class="badge badge-type">Withdrawal</span>
                  </td>
                  <td class="strong">
                    <span v-if="item._type==='conversion'">{{ item.from_currency }} → {{ item.to_currency }}</span>
                    <span v-else-if="item._type==='transfer'">{{ item.direction==='out' ? 'Sent' : 'Received' }} {{ item.currency }}</span>
                    <span v-else>{{ item.currency }} withdrawal</span>
                  </td>
                  <td :style="item._type==='transfer' ? (item.direction==='out' ? 'color:#ef4444;font-weight:600' : 'color:var(--primary);font-weight:600') : 'color:var(--primary);font-weight:600'">
                    <span v-if="item._type==='transfer'">{{ item.direction==='out' ? '−' : '+' }}{{ fmt(item.amount, item.currency) }} {{ item.currency }}</span>
                    <span v-else-if="item._type==='conversion'">{{ fmt(item.from_amount||item.amount, item.from_currency) }} {{ item.from_currency }}</span>
                    <span v-else>{{ fmt(item.amount, item.currency) }} {{ item.currency }}</span>
                  </td>
                  <td>
                    <span v-if="item._type==='conversion'" class="badge badge-success">Completed</span>
                    <span v-else :class="['badge', txStatusClass(item.status)]">{{ txStatusLabel(item.status) }}</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </template>
      </div>

      <!-- ── WALLETS ── -->
      <div class="page" :class="{active:currentPage==='wallets'}">
        <div class="page-header"><div><div class="page-title">My Wallets</div><div class="page-sub">Current balances across all currencies</div></div></div>
        <div v-if="walletsLoading" class="loading"><div class="spinner"></div>Loading...</div>
        <div v-else-if="!wallets.length" class="empty-state">No wallets found</div>
        <div v-else class="wallets-grid">
          <div v-for="w in wallets" :key="w.id" :class="['wallet-card', walletClass(w.currency)]">
            <div class="wallet-watermark">{{ w.currency }}</div>
            <div class="wallet-currency">{{ w.currency }}<span style="font-weight:300;font-size:0.9em">{{ curSym(w.currency) }}</span></div>
            <div class="wallet-balance">{{ curSym(w.currency) }}{{ parseFloat(w.balance||0).toLocaleString('en-US',{maximumFractionDigits:8}) }}</div>
            <div class="wallet-id" @click="copyWalletId(w.id)" title="Click to copy">
              Wallet {{ w.id || '—' }}
              <span class="wallet-copy-hint">📋 copy</span>
            </div>
          </div>
        </div>
      </div>

      <!-- ── CONVERT ── -->
      <div class="page" :class="{active:currentPage==='convert'}">
        <div class="page-header"><div><div class="page-title">Convert Currency</div><div class="page-sub">Exchange between your wallets at live market rates</div></div></div>
        <div class="form-card">
          <div class="form-card-title">New Conversion</div>
          <!-- Inline wallet balances -->
          <div v-if="wallets.length" class="inline-balance-strip">
            <div v-for="w in wallets.slice(0,4)" :key="w.id" class="ibs-card">
              <div class="ibs-label">{{ w.currency }}</div>
              <div class="ibs-val">{{ curSym(w.currency) }}{{ parseFloat(w.balance||0).toLocaleString('en-US',{maximumFractionDigits:4}) }}</div>
            </div>
          </div>
          <div class="rate-display"><div class="rate-dot"></div><span>{{ currentRateText }}</span></div>
          <form @submit.prevent="handleConvert">
            <div class="form-row">
              <div class="form-group">
                <label class="form-label">From Currency</label>
                <div v-if="fromWalletBalance" style="font-family:var(--mono);font-size:0.68rem;color:var(--ink-soft);margin-bottom:4px;">Balance: {{ fromWalletBalance }}</div>
                <select class="select-input" v-model="convFrom">
                  <option value="USD">USD</option><option value="EUR">EUR</option><option value="GBP">GBP</option><option value="BTC">BTC</option><option value="ETH">ETH</option>
                </select>
              </div>
              <div class="form-group"><label class="form-label">To Currency</label>
                <select class="select-input" v-model="convTo">
                  <option value="EUR">EUR</option><option value="USD">USD</option><option value="GBP">GBP</option><option value="BTC">BTC</option><option value="ETH">ETH</option>
                </select>
              </div>
            </div>
            <div class="form-group"><label class="form-label">Amount</label><input class="form-input" type="number" v-model="convAmount" placeholder="0.00" step="any" min="0.01" required /></div>
            <div v-if="convPreview" style="font-family:var(--mono);font-size:0.75rem;color:var(--primary);margin-bottom:1rem;padding:0.5rem 0.75rem;background:var(--primary-bg);border-radius:var(--radius);">{{ convPreview }}</div>
            <div class="info-box">A conversion fee of <strong>0.30%</strong> applies to all conversions.</div>
            <button class="btn-primary" type="submit" :disabled="convLoading">{{ convLoading ? 'Processing...' : 'Confirm Conversion' }}</button>
            <div v-if="convError" class="error-msg show">{{ convError }}</div>
          </form>
          <!-- Inline result — no need to navigate away -->
          <div v-if="convResult" class="result-card show">
            <div class="result-card-title">✓ Conversion complete</div>
            <div class="result-card-amount">+{{ fmt(convResult.to_amount, convResult.to_currency) }} {{ convResult.to_currency }}</div>
            <div class="result-card-sub">from {{ fmt(convResult.from_amount, convResult.from_currency) }} {{ convResult.from_currency }} · Your balances have been updated</div>
          </div>
        </div>
      </div>

      <!-- ── SEND MONEY ── -->
      <div class="page" :class="{active:currentPage==='withdraw'}">
        <div class="page-header"><div><div class="page-title">Send Money</div><div class="page-sub">Transfer funds to another Wiseling user instantly</div></div></div>
        <!-- My account number card -->
        <div class="form-card" style="margin-bottom:1rem;">
          <div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:0.5rem;">
            <div>
              <div style="font-size:0.7rem;color:var(--ink-soft);letter-spacing:0.08em;text-transform:uppercase;margin-bottom:0.25rem;">Your Wiseling Account Number</div>
              <div style="font-family:'DM Mono',monospace;font-size:1.1rem;color:var(--primary);letter-spacing:0.12em;">{{ myAccountNumber || '—' }}</div>
            </div>
            <button @click="copyAccountNumber" style="background:var(--surface2);border:1px solid var(--border);color:var(--ink-mid);font-size:0.75rem;padding:0.4rem 0.9rem;border-radius:6px;cursor:pointer;">Copy</button>
          </div>
        </div>
        <div class="form-card">
          <div class="form-card-title">New Transfer</div>
          <!-- Inline wallet balance for selected currency -->
          <div v-if="wdWalletBalance" style="font-family:var(--mono);font-size:0.72rem;color:var(--ink-soft);margin-bottom:1rem;padding:0.5rem 0.75rem;background:var(--bg3);border-radius:var(--radius);border:1px solid var(--border);">
            Available: <span style="color:var(--ink);font-weight:600;">{{ wdWalletBalance }}</span>
          </div>
          <form @submit.prevent="initiateWithdraw">
            <div class="form-group">
              <label class="form-label">Recipient Account Number</label>
              <input class="form-input" type="text" v-model="wdAccountNumber" @input="onAccountInput" placeholder="0000-0000-0000" maxlength="14" required />
              <div v-if="wdRecipientLoading" style="margin-top:0.5rem;font-family:var(--mono);font-size:0.75rem;color:var(--ink-soft);">Looking up account...</div>
              <div v-else-if="wdRecipient && wdRecipient.found" style="margin-top:0.5rem;padding:0.6rem 0.9rem;background:rgba(62,207,142,0.07);border:1px solid rgba(62,207,142,0.2);border-radius:8px;font-size:0.8rem;color:var(--primary);">✓ Sending to: {{ wdRecipient.email }}</div>
              <div v-else-if="wdRecipient && !wdRecipient.found" style="margin-top:0.5rem;padding:0.6rem 0.9rem;background:rgba(239,68,68,0.07);border:1px solid rgba(239,68,68,0.2);border-radius:8px;font-size:0.8rem;color:#ef4444;">✗ Account not found</div>
            </div>
            <div class="form-group"><label class="form-label">Currency</label>
              <select class="select-input" v-model="wdCurrency">
                <option value="USD">USD — US Dollar</option><option value="EUR">EUR — Euro</option><option value="GBP">GBP — British Pound</option>
              </select>
            </div>
            <div class="form-group"><label class="form-label">Amount</label><input class="form-input" type="number" v-model="wdAmount" placeholder="0.00" step="any" min="0.01" required /></div>
            <div class="info-box">Transfers between Wiseling accounts are <strong>instant</strong> and <strong>fee-free</strong>.</div>
            <button class="btn-primary" type="submit" :disabled="!wdRecipient?.found || !wdAmount">Review & Send</button>
            <div v-if="wdError" class="error-msg show">{{ wdError }}</div>
          </form>
          <!-- Inline result -->
          <div v-if="wdResult" class="result-card show">
            <div class="result-card-title">✓ Transfer sent</div>
            <div class="result-card-amount">{{ wdAmount }} {{ wdCurrency }}</div>
            <div class="result-card-sub">Reference: {{ wdResult.id || '—' }} · Your balance has been updated</div>
          </div>
          <!-- Recent recipients -->
          <div v-if="recentRecipients.length" style="margin-top:1.5rem;">
            <div style="font-size:0.7rem;color:var(--ink-soft);letter-spacing:0.08em;text-transform:uppercase;margin-bottom:0.75rem;">Recent Recipients</div>
            <div style="display:flex;flex-direction:column;gap:0.4rem;">
              <div v-for="r in recentRecipients" :key="r.accountNumber" class="recipient-item" @click="fillRecipient(r.accountNumber, r.email)">
                <div><div style="font-size:0.85rem;color:var(--ink);">{{ r.email }}</div><div style="font-size:0.75rem;color:var(--ink-soft);font-family:'DM Mono',monospace;">{{ r.accountNumber }}</div></div>
                <div style="font-size:0.75rem;color:var(--primary);">Send →</div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- ── HISTORY ── -->
      <div class="page" :class="{active:currentPage==='history'}">
        <div class="page-header"><div><div class="page-title">Transactions</div><div class="page-sub">Your complete transaction history</div></div></div>
        <div class="filter-tabs">
          <button v-for="f in ['all','conversions','withdrawals','transfers']" :key="f" class="filter-btn" :class="{active:historyFilter===f}" @click="historyFilter=f">{{ f }}</button>
        </div>
        <div class="table-card">
          <div v-if="historyLoading" class="loading"><div class="spinner"></div>Loading...</div>
          <div v-else-if="!filteredHistory.length" class="empty-state">No transactions found</div>
          <table v-else>
            <thead><tr><th>Type</th><th>Details</th><th>Amount</th><th>Status</th><th>Date</th></tr></thead>
            <tbody>
              <tr v-for="item in filteredHistory" :key="item.id + item._type">
                <td>
                  <span v-if="item._type==='conversion'" class="badge badge-type">Conversion</span>
                  <span v-else-if="item._type==='transfer'" class="badge badge-type" style="background:rgba(139,92,246,0.15);color:#a78bfa;">Transfer</span>
                  <span v-else class="badge badge-type">Withdrawal</span>
                </td>
                <td class="strong">
                  <span v-if="item._type==='conversion'">{{ item.from_currency }} → {{ item.to_currency }}</span>
                  <span v-else-if="item._type==='transfer'">{{ item.direction==='out' ? 'Sent' : 'Received' }} {{ item.currency }}</span>
                  <span v-else>{{ item.currency }} withdrawal</span>
                </td>
                <td :style="item._type==='transfer' ? (item.direction==='out' ? 'color:#ef4444;font-weight:600' : 'color:var(--primary);font-weight:600') : 'color:var(--primary);font-weight:600'">
                  <span v-if="item._type==='transfer'">{{ item.direction==='out' ? '−' : '+' }}{{ item.amount }} {{ item.currency }}</span>
                  <span v-else-if="item._type==='conversion'">{{ item.from_amount||item.amount }} {{ item.from_currency }}</span>
                  <span v-else>{{ item.amount }} {{ item.currency }}</span>
                </td>
                <td>
                  <span v-if="item._type==='conversion'" class="badge badge-success">Completed</span>
                  <template v-else>
                    <span :class="['badge', txStatusClass(item.status)]">{{ txStatusLabel(item.status) }}</span>
                    <span v-if="['pending','processing'].includes(item.status)" class="pending-spinner" style="margin-left:6px;display:inline-block;"></span>
                  </template>
                </td>
                <td style="font-family:var(--mono);font-size:0.75rem;color:var(--ink-soft)">{{ date(item.created_at) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

    </div>

    <!-- Mobile nav -->
    <nav class="mobile-nav">
      <button v-for="(label, key) in PAGE_NAMES" :key="key" class="mobile-nav-item" :class="{active:currentPage===key}" @click="navigate(key)">
        <span class="mobile-nav-icon">{{ {overview:'◎',wallets:'▣',convert:'⇄',withdraw:'↑',history:'≡'}[key] }}</span>
        {{ label.split(' ')[0] }}
      </button>
    </nav>
  </div>

</div>
  `
}).mount('#app');