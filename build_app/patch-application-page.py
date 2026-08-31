#!/usr/bin/env python3
"""
patch-application-page.py <APP_DIR>

Na pagina /application:
  - troca o <button ... disabled> "GERAR APK" por um botao que abre um modal;
  - injeta o modal (barra de progresso -> link de download com contagem de 40 min);
  - injeta o JS que fala com POST /application/apk e GET /application/apk/status/:id.

Idempotente: rodar de novo nao duplica nada. Chamado pelo install.sh a cada deploy.
"""
import re
import sys
from pathlib import Path

MARK = "id=\"apkModal\""

BUTTON = (
    '<button type="button" id="btn-gerar-apk" '
    'class="btn btn-dark flex-fill me-1 w-50 d-flex align-items-center justify-content-center">\n'
    '                    <i class="bi bi-android"></i><span>&nbsp;GERAR APK</span>\n'
    '                  </button>'
)

# SO o <button> que contem "GERAR APK" — o "tempered token" (?:(?!</button>).)
# impede que o match atravesse o </button> de botoes anteriores (NOVO, IMPORTAR).
BUTTON_RE = re.compile(
    r"<button\b(?:(?!</button>).)*?GERAR APK(?:(?!</button>).)*?</button>",
    re.IGNORECASE | re.DOTALL,
)

MODAL = """
<div class="modal fade" id="apkModal" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content">
      <div class="modal-header">
        <h1 class="modal-title fs-5"><i class="bi bi-android2"></i>&nbsp;GERAR APK</h1>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Fechar"></button>
      </div>
      <div class="modal-body">
        <div id="apkProgressWrap">
          <p class="mb-2 small text-muted" id="apkStage">iniciando...</p>
          <div class="progress" role="progressbar" style="height:22px;">
            <div id="apkBar" class="progress-bar progress-bar-striped progress-bar-animated bg-dark"
                 style="width:3%;">3%</div>
          </div>
          <p class="mt-3 mb-0 small text-muted">
            Gerando o app com as suas credenciais. Leva alguns segundos &mdash; pode manter esta janela aberta.
          </p>
        </div>
        <div id="apkDoneWrap" class="d-none text-center">
          <i class="bi bi-check-circle-fill text-success" style="font-size:2.5rem;"></i>
          <p class="mt-2 mb-3">Seu APK esta pronto.</p>
          <a id="apkDownload" class="btn btn-dark w-100" target="_self" download>
            <i class="bi bi-download"></i>&nbsp;BAIXAR APK
          </a>
          <p class="mt-2 mb-0 small text-muted" id="apkExpiry">disponivel por 40:00</p>
          <button type="button" class="btn btn-link btn-sm mt-1 apk-retry">gerar outro</button>
        </div>
        <div id="apkErrorWrap" class="d-none text-center">
          <i class="bi bi-x-circle-fill text-danger" style="font-size:2.5rem;"></i>
          <p class="mt-2 mb-3" id="apkErrorMsg">Falha ao gerar o APK.</p>
          <button type="button" class="btn btn-dark w-100 apk-retry">tentar de novo</button>
        </div>
      </div>
    </div>
  </div>
</div>
<script>
  (function () {
    var btn = document.getElementById('btn-gerar-apk');
    var modalEl = document.getElementById('apkModal');
    if (!btn || !modalEl || typeof bootstrap === 'undefined') return;

    var modal = new bootstrap.Modal(modalEl, { backdrop: 'static' });
    var bar = document.getElementById('apkBar');
    var stage = document.getElementById('apkStage');
    var wrapProg = document.getElementById('apkProgressWrap');
    var wrapDone = document.getElementById('apkDoneWrap');
    var wrapErr = document.getElementById('apkErrorWrap');
    var errMsg = document.getElementById('apkErrorMsg');
    var dl = document.getElementById('apkDownload');
    var expiry = document.getElementById('apkExpiry');
    var poll = null, countdown = null;

    function view(which) {
      wrapProg.classList.toggle('d-none', which !== 'prog');
      wrapDone.classList.toggle('d-none', which !== 'done');
      wrapErr.classList.toggle('d-none', which !== 'err');
    }
    function setBar(p) {
      p = Math.max(3, Math.min(100, p | 0));
      bar.style.width = p + '%';
      bar.textContent = p + '%';
    }
    function stop() {
      if (poll) clearInterval(poll);
      if (countdown) clearInterval(countdown);
      poll = countdown = null;
    }
    function mmss(s) {
      s = Math.max(0, s | 0);
      var m = Math.floor(s / 60), r = s % 60;
      return m + ':' + (r < 10 ? '0' : '') + r;
    }
    function fail(msg) {
      stop();
      errMsg.textContent = msg || 'Falha ao gerar o APK.';
      view('err');
    }
    function done(s) {
      setBar(100);
      bar.classList.remove('progress-bar-animated', 'progress-bar-striped');
      dl.href = s.downloadUrl;
      dl.classList.remove('disabled');
      view('done');
      var left = s.expiresInSec || 2400;
      showLeft(left);
      countdown = setInterval(function () { left -= 1; showLeft(left); }, 1000);
    }
    function showLeft(left) {
      if (left <= 0) {
        if (countdown) clearInterval(countdown);
        expiry.textContent = 'link expirado — gere outro';
        dl.classList.add('disabled');
        dl.removeAttribute('href');
      } else {
        expiry.textContent = 'disponivel por ' + mmss(left);
      }
    }
    function track(id) {
      poll = setInterval(function () {
        fetch('/application/apk/status/' + id, { headers: { Accept: 'application/json' } })
          .then(function (r) { if (!r.ok) throw new Error(); return r.json(); })
          .then(function (s) {
            if (s.status === 'building') {
              setBar(s.percent);
              stage.textContent = s.stage || 'processando...';
            } else if (s.status === 'done') {
              stop();
              done(s);
            } else {
              fail(s.error);
            }
          })
          .catch(function () { /* re-tenta no proximo tick */ });
      }, 1500);
    }
    function start() {
      stop();
      view('prog');
      setBar(3);
      stage.textContent = 'iniciando...';
      bar.classList.add('progress-bar-animated', 'progress-bar-striped');
      modal.show();
      fetch('/application/apk', { method: 'POST', headers: { Accept: 'application/json' } })
        .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
        .then(function (j) { track(j.id); })
        .catch(function () { fail('Nao foi possivel iniciar a geracao. Recarregue a pagina e tente de novo.'); });
    }

    btn.addEventListener('click', start);
    document.querySelectorAll('.apk-retry').forEach(function (b) { b.addEventListener('click', start); });
    modalEl.addEventListener('hidden.bs.modal', stop);
  })();
</script>
"""


def main() -> int:
    if len(sys.argv) < 2:
        print("uso: patch-application-page.py <APP_DIR>", file=sys.stderr)
        return 2

    page = Path(sys.argv[1]) / "frontend" / "pages" / "application" / "index.html"
    if not page.is_file():
        print(f"[patch] pagina nao encontrada: {page}", file=sys.stderr)
        return 1

    html = page.read_text(encoding="utf-8")
    if MARK in html:
        print("[patch] modal GERAR APK ja aplicado — nada a fazer.")
        return 0

    new_html, n = BUTTON_RE.subn(BUTTON, html, count=1)
    if n == 0:
        print("[patch] botao 'GERAR APK' nao encontrado no HTML (layout mudou?).", file=sys.stderr)
        return 1

    if "</body>" in new_html:
        new_html = new_html.replace("</body>", MODAL + "\n</body>", 1)
    else:
        new_html += MODAL

    page.write_text(new_html, encoding="utf-8")
    print(f"[patch] botao + modal GERAR APK aplicados em {page}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
