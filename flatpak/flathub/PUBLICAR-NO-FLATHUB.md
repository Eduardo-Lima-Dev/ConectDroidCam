# Publicar o ConectDroidCam no Flathub

Checklist completo do que já está pronto no repositório e do que você executa no GitHub e no `flathub/flathub`.

## O que já está organizado no projeto

- `LICENSE`: GNU GPLv3 (`GPL-3.0-or-later`), compatível com o Flathub e com o `ffmpeg` mínimo embutido.
- Identificador do app no Linux: `io.github.eduardo_lima_dev.ConectDroidCam` (compatível com a conta GitHub `Eduardo-Lima-Dev`, com `-` convertido para `_` pela regra do D-Bus).
- [`../io.github.eduardo_lima_dev.ConectDroidCam.desktop`](../io.github.eduardo_lima_dev.ConectDroidCam.desktop) e [`../../packaging/linux/io.github.eduardo_lima_dev.ConectDroidCam.desktop`](../../packaging/linux/io.github.eduardo_lima_dev.ConectDroidCam.desktop) unificados, com tradução em inglês e português.
- Ícones em todos os tamanhos (`16x16` até `512x512`) em `packaging/linux/icons/hicolor/`.
- [`../io.github.eduardo_lima_dev.ConectDroidCam.metainfo.xml`](../io.github.eduardo_lima_dev.ConectDroidCam.metainfo.xml) no formato exigido pelo AppStream do Flathub (textos padrão em inglês + `xml:lang="pt-BR"`, licença, `<developer>`, URLs, OARS, `<screenshots>`, `<releases>`).
- Detecção automática de Flatpak no app (`virtualWebcamSetupCommand`): dentro do Flatpak, o comando copiado extrai o `linux-webcam-virtual.sh` empacotado em `/app/share/conectdroidcam/linux-webcam-virtual.sh`, sem precisar do repositório clonado.
- Template de build offline a partir do código-fonte: [`flatpak-flutter.yml`](flatpak-flutter.yml) + script [`../../scripts/flatpak/preparar-flathub.sh`](../../scripts/flatpak/preparar-flathub.sh).

## Passo a passo para publicar

### 1. Pré-requisitos no GitHub (ações suas)

1. **Capturar a tela principal:** tire uma captura de tela limpa da janela do ConectDroidCam e salve em `flatpak/screenshots/main.png` (veja [`../screenshots/README.md`](../screenshots/README.md)).
2. **Revisar e publicar o repositório:** o Flathub só compila repositórios **públicos**. Faça o merge do branch `feat/flathub` para a `main` e mude a visibilidade de `Eduardo-Lima-Dev/ConectDroidCam` para **Public** nas configurações do GitHub.
3. **Criar a tag `v0.1.0`:** depois do commit da captura de tela estar na `main`, crie e envie a tag:
   ```sh
   git tag -a v0.1.0 -m "Release v0.1.0"
   git push origin v0.1.0
   ```
   > Verifique no navegador se `https://raw.githubusercontent.com/Eduardo-Lima-Dev/ConectDroidCam/v0.1.0/flatpak/screenshots/main.png` abre sem erro 404.

### 2. Gerar os arquivos offline e validar localmente

Instale os runtimes/extensões necessários uma vez:

```sh
flatpak install --user flathub \
  org.flatpak.Builder \
  org.gnome.Platform//51 \
  org.gnome.Sdk//51 \
  org.freedesktop.Sdk.Extension.rust-stable//26.08
```

Gere o manifesto final do Flathub e valide com `flatpak-builder-lint`:

```sh
scripts/flatpak/preparar-flathub.sh --tag v0.1.0
```

Isso cria em `dist/flathub-pr/`:
- `io.github.eduardo_lima_dev.ConectDroidCam.yml`
- `pubspec-sources.json`
- `cargo-sources.json`
- `flutter-sdk-3.44.4.json` (e o script `setup-flutter.sh` / arquivos auxiliares gerados pelo `flatpak-flutter`)

### 3. Abrir o Pull Request no `flathub/flathub`

1. Faça um fork de `https://github.com/flathub/flathub` no GitHub (**desmarque** *"Copy the master branch only"*, pois é preciso o branch `new-pr`).
2. Clone o fork no branch `new-pr` e crie um branch para o app:
   ```sh
   git clone --branch=new-pr git@github.com:Eduardo-Lima-Dev/flathub.git
   cd flathub
   git checkout -b conectdroidcam-submission new-pr
   ```
3. Copie **todos** os arquivos de `dist/flathub-pr/` para a raiz do clone do `flathub` (e inclua um `flathub.json` apenas se precisar limitar arquiteturas, por exemplo `{"only-arches": ["x86_64"]}`).
4. Faça o commit e o push:
   ```sh
   git add .
   git commit -m "Add io.github.eduardo_lima_dev.ConectDroidCam"
   git push origin conectdroidcam-submission
   ```
5. No GitHub, abra o Pull Request contra **`flathub/flathub` branch `new-pr`** (nunca `master`) com o título:
   `Add io.github.eduardo_lima_dev.ConectDroidCam`

### 4. Justificativa sugerida para a descrição do PR no Flathub

Os revisores do Flathub pedem justificativa explícita para permissões amplas (`--device=all`):

- **`--device=all`**: necessário para descobrir dispositivos V4L2 em `/sys/class/video4linux` e escrever frames de vídeo nos dispositivos virtuais `v4l2loopback` (`/dev/video10`–`/dev/video15`), assim como o OBS Studio (`com.obsproject.Studio`) já faz no Flathub.
- **`--share=network`**: necessário para descoberta local via mDNS (`_conectdroidcam._tcp`) e transporte TLS/TCP direto com o aplicativo do celular na rede Wi-Fi local (sem servidores externos).
- **`v4l2loopback` no host**: o módulo de kernel `v4l2loopback` não pode ser empacotado dentro do Flatpak; o aplicativo detecta sua ausência, funciona no modo de prévia/teste e fornece ao usuário o comando exato usando o script auxiliar empacotado em `/app/share/conectdroidcam/linux-webcam-virtual.sh`.
