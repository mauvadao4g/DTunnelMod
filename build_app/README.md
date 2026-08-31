# build_app/ — gerador do APK do DTunnel Mod

Gera um APK personalizado por usuário a partir de um **APK base**, trocando dois
assets e reassinando. Não recompila código nem recursos — não precisa de apktool
nem do Android SDK completo, só de **JDK + apksigner + zipalign**.

## Conteúdo

| Arquivo             | Função |
|---------------------|--------|
| `DTMod_4.5.7.apk`   | APK base (molde). Você coloca aqui. |
| `setup.sh`          | Instala as dependências (Debian/Ubuntu). |
| `build-apk.sh`      | Gera o APK: injeta os assets, `zipalign`, `apksigner`. |
| `patch-application-page.py` | Troca o botão "GERAR APK" (`/application`) por um que abre um **modal com barra de progresso** → **link de download** (usado pelo `install.sh`). |
| `panel-src/routes/DTunnel/Apk/*.ts` | Rotas do painel: `POST /application/apk` (dispara), `GET .../status/:id` (progresso), `GET .../download/:id` (baixa). `_apk-jobs.ts` = estado + limpeza. |
| `dtunnelmod.json`   | Modelo do `assets/dtunnelmod.json` (fallback). |
| `user_id.txt`       | Exemplo do `assets/user_id.txt`. |
| `keystore/dtmod.jks`| Keystore de assinatura (criada no 1º build). **Faça backup.** |
| `dist/`             | APKs gerados. |

`keystore/` e `dist/` são ignorados pelo git.

## O que o app lê

O DTunnel Mod busca o painel e o usuário nestes dois assets:

- `assets/user_id.txt` → **`User.id` (o UUID)** do usuário. É o `dtunnel-token` que a
  API `/api/dtunnelmod` do painel usa pra achar as configs (`AppConfig.user_id`).
- `assets/dtunnelmod.json` → `{ "url": "<painel hospedado>", "credits": ..., "channel": ..., "group": ... }`.
  O `build-apk.sh` só reescreve o campo **`url`**; o resto do JSON base é preservado.

## Uso manual

```bash
./setup.sh                     # uma vez, instala JDK + apksigner + zipalign + zip + jq
./build-apk.sh --user-id maudavpn --url https://painel.seudominio.com
# -> dist/DTMod-maudavpn.apk  (assinado, v2+v3)
```

Opções úteis: `--base <apk>`, `--out <apk>`, `--keystore <jks>`, `--storepass <senha>`,
`--print-json` (imprime `{"apk","sha256","size"}` no stdout, logs vão pro stderr),
`--quiet`. Veja `./build-apk.sh --help`.

## Aplicar ao painel (botão "GERAR APK" em `/application`)

### Automático — pelo `install.sh`

O `install.sh` deste repo detecta `build_app/` (base `.apk` + `build-apk.sh`) e, a cada
instalação (local ou `./install.sh --remote`):

1. instala o toolchain (`default-jdk-headless apksigner zipalign`);
2. copia pra `<APP_DIR>/app_base/`: `apk-builder.sh` (= `build-apk.sh`), `base.apk`, cria `panel.jks`;
3. injeta as rotas `src/routes/DTunnel/Apk/*.ts` (auto-registradas pelo `handle-routes`);
4. roda `patch-application-page.py` → botão vira **modal com progresso** + **link de download**;
5. `npm run build` compila com as rotas;
6. faz um smoke test do gerador.

A senha da keystore vem de `APK_KEYSTORE_PASS` no `.env` (o `install.sh` gera).
**Backup de `<APP_DIR>/app_base/panel.jks`** — perder = usuários reinstalam.

Depois do deploy, o usuário logado clica em **GERAR APK**: abre um modal com barra de
progresso; ao terminar aparece **BAIXAR APK**. O `.apk` fica no servidor por **40 min**
(`assets/user_id.txt` = `User.id`, `assets/dtunnelmod.json.url` = `PUBLIC_URL`) e depois é
apagado por uma varredura periódica. Cada build ~5–15 s; simultâneos são seguros.

### Fluxo HTTP

| Método | Rota | Resposta |
|---|---|---|
| `POST` | `/application/apk` | `202 {id, statusUrl}` — dispara a build em background |
| `GET` | `/application/apk/status/:id` | `{status, percent, stage}`; quando `done`: `+{downloadUrl, size, sha256, expiresInSec}` |
| `GET` | `/application/apk/download/:id` | o `.apk` (`attachment`); `410` depois de 40 min |

### Manual (painel já rodando)

```bash
# na VPS, dentro do <APP_DIR> do painel:
sudo bash /caminho/DTunnelMod/build_app/setup.sh
install -Dm755 build_app/build-apk.sh                                app_base/apk-builder.sh
install -Dm644 build_app/DTMod_4.5.7.apk                             app_base/base.apk
mkdir -p src/routes/DTunnel/Apk && rm -f src/routes/DTunnel/Apk/*.ts
install -m644 build_app/panel-src/routes/DTunnel/Apk/*.ts            src/routes/DTunnel/Apk/
python3 build_app/patch-application-page.py "$PWD"
npm run build && systemctl restart dtunnel-<slug>
```

## Assinatura / keystore

- A 1ª execução cria `keystore/dtmod.jks` (RSA 2048, validade ~27 anos), senha
  `APK_KEYSTORE_PASS` ou `dtunnelmod`.
- **Guarde essa keystore.** Se ela mudar, o Android trata o APK como outro app e o
  usuário precisa desinstalar o anterior para instalar a atualização.
- Como a assinatura é própria (não a da Play Store), para instalar por cima do app
  da loja é preciso desinstalar o original antes.
