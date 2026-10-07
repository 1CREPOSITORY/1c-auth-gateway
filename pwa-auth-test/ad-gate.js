'use strict';

var FPS_SERVICES = [];

function showAdGate() {
  var gate = document.getElementById('adGate');
  if (gate) gate.classList.remove('hidden');
  document.body.classList.add('ad-locked');
}

function hideAdGate() {
  var gate = document.getElementById('adGate');
  if (gate) gate.classList.add('hidden');
  document.body.classList.remove('ad-locked');
}

function setAdStatus(message, type) {
  var el = document.getElementById('adStatus');
  if (!el) return;
  el.textContent = message || '';
  el.className = 'ad-status' + (message ? ' visible' : '') + (type ? ' ' + type : '');
}

function rememberAdUsername(username) {
  var remember = document.getElementById('adRememberUsername');
  if (remember && remember.checked) localStorage.setItem('ad-login-username', username);
  else localStorage.removeItem('ad-login-username');
}

function applyAdIdentity(me) {
  window.AD_USER = me.osUser || '';
  window.AD_AUTH_TYPE = me.authType || '';
  var menuUser = document.getElementById('menuUserName');
  if (menuUser && me.osUser) menuUser.textContent = me.osUser;
}

function loadFpsServices() {
  return fetch('/auth/fps/services', {
    method: 'GET',
    credentials: 'include',
    cache: 'no-store',
    headers: { 'Accept': 'application/json' }
  }).then(function (response) {
    return response.json().then(function (data) {
      if (!response.ok || !data || data.ok !== true) throw new Error('FPS');
      FPS_SERVICES = data.services || [];
      return FPS_SERVICES;
    });
  }).catch(function () {
    FPS_SERVICES = [{ id: 'zno', title: 'Согласование ЗНО', entry: '/pwa-auth-test/' }];
    return FPS_SERVICES;
  });
}

function enterApplication(me) {
  applyAdIdentity(me);
  hideAdGate();
  setAdStatus('', '');
  window.SESSION_READY = true;
  if (typeof openZnoApplication === 'function') openZnoApplication();
}

function startAdGate() {
  var params = new URLSearchParams(window.location.search);
  if (params.get('sso') === 'unavailable') {
    setAdStatus('SSO is not available for this client. Use domain username and password.', 'error');
    params.delete('sso');
    var next = window.location.pathname + (params.toString() ? '?' + params.toString() : '');
    window.history.replaceState({}, '', next);
  }

  var saved = localStorage.getItem('ad-login-username');
  var usernameEl = document.getElementById('adUsername');
  var rememberEl = document.getElementById('adRememberUsername');
  if (saved && usernameEl) {
    usernameEl.value = saved;
    if (rememberEl) rememberEl.checked = true;
  }

  fetch('/auth/me', {
    method: 'GET',
    credentials: 'include',
    cache: 'no-store',
    headers: { 'Accept': 'application/json' }
  }).then(function (response) {
    return response.text().then(function (text) {
      return { ok: response.ok, text: text };
    });
  }).then(function (result) {
    var data = {};
    try { data = result.text ? JSON.parse(result.text) : {}; } catch (e) { data = {}; }
    if (!result.ok || !data.ok || !data.osUser) {
      showAdGate();
      return;
    }
    enterApplication(data);
  }).catch(function () {
    showAdGate();
    setAdStatus('Authentication service is unavailable.', 'error');
  });
}

function submitAdLogin(event) {
  if (event) event.preventDefault();
  var usernameEl = document.getElementById('adUsername');
  var passwordEl = document.getElementById('adPassword');
  var button = document.getElementById('adLoginBtn');
  var sso = document.getElementById('adSsoBtn');
  var username = usernameEl ? usernameEl.value.trim() : '';
  var password = passwordEl ? passwordEl.value : '';

  if (!username || !password) {
    setAdStatus('Enter username and password.', 'error');
    return;
  }

  rememberAdUsername(username);
  if (button) button.disabled = true;
  if (sso) sso.disabled = true;
  setAdStatus('Checking credentials in Active Directory...', '');

  var payload = JSON.stringify({ username: username, password: password });
  password = '';
  if (passwordEl) passwordEl.value = '';

  fetch('/auth/login', {
    method: 'POST',
    credentials: 'include',
    cache: 'no-store',
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    },
    body: payload
  }).then(function (response) {
    return response.text().then(function (text) {
      return { ok: response.ok, status: response.status, text: text };
    });
  }).then(function (result) {
    var data = {};
    try { data = result.text ? JSON.parse(result.text) : {}; } catch (e) { data = {}; }
    if (result.status === 401) {
      setAdStatus('Invalid username or password.', 'error');
      showAdGate();
      return;
    }
    if (result.status === 429) {
      setAdStatus(data.error || 'Too many attempts. Try again later.', 'error');
      showAdGate();
      return;
    }
    if (!result.ok || !data.ok || !data.osUser) {
      setAdStatus('Authentication service returned HTTP ' + result.status + '.', 'error');
      showAdGate();
      return;
    }
    enterApplication(data);
  }).catch(function () {
    setAdStatus('Authentication service is unavailable.', 'error');
    showAdGate();
  }).then(function () {
    payload = '';
    if (button) button.disabled = false;
    if (sso) sso.disabled = false;
  });
}

function startSsoLogin() {
  window.location.assign('/auth/sso/login');
}

function adLogout() {
  fetch('/auth/logout', {
    method: 'POST',
    credentials: 'include',
    cache: 'no-store',
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json'
    },
    body: '{}'
  }).finally(function () {
    window.AD_USER = '';
    window.AD_AUTH_TYPE = '';
    window.SESSION_READY = false;
    FPS_SERVICES = [];
    if (typeof AUTH_HEADER !== 'undefined') AUTH_HEADER = '';
    if (typeof showAuthGate === 'function') showAuthGate('');
    showAdGate();
    setAdStatus('', '');
  });
}

document.addEventListener('DOMContentLoaded', function () {
  var form = document.getElementById('adLoginForm');
  if (form) form.addEventListener('submit', submitAdLogin);
  var sso = document.getElementById('adSsoBtn');
  if (sso) sso.addEventListener('click', startSsoLogin);
  var toggle = document.getElementById('adTogglePassword');
  var passwordEl = document.getElementById('adPassword');
  if (toggle && passwordEl) {
    toggle.addEventListener('click', function () {
      var show = passwordEl.type === 'password';
      passwordEl.type = show ? 'text' : 'password';
      toggle.setAttribute('aria-label', show ? 'Hide password' : 'Show password');
    });
  }
});
