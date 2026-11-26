# Flatpak do ConectDroidCam

O app do Linux é empacotado como Flatpak, com o id `io.github.eduardo_lima_dev.ConectDroidCam`. O manifesto fica em [`flatpak/io.github.eduardo_lima_dev.ConectDroidCam.yml`](../flatpak/io.github.eduardo_lima_dev.ConectDroidCam.yml).

## Instalar com atualizações automáticas

O workflow publica um repositório Flatpak próprio, assinado, no GitHub Pages (`https://eduardo-lima-dev.github.io/ConectDroidCam/`). Cadastre-o uma vez e instale:

```sh
flatpak remote-add --user --if-not-exists conectdroidcam https://eduardo-lima-dev.github.io/ConectDroidCam/conectdroidcam.flatpakrepo
flatpak install --user conectdroidcam io.github.eduardo_lima_dev.ConectDroidCam
```

Depois disso, cada release da `main` chega pelo `flatpak update` e pela loja do sistema (GNOME Software, Discover). O `.flatpak` anexado às releases também já aponta para esse repositório: quem o instala passa a receber as atualizações sem precisar do `remote-add`.

O app publicado segue o ramo `stable`. Se você tinha o app instalado pelo `instalar-local.sh` ou pelo manifesto de testes do Flathub (ramo `master`), remova-o antes, para não ficar com dois: `flatpak uninstall --user io.github.eduardo_lima_dev.ConectDroidCam//master`.

## Instalar localmente (sem sudo)

```sh
scripts/flatpak/instalar-local.sh
```

O script gera o bundle de release (`flutter build linux --release`), monta o Flatpak com `org.flatpak.Builder` e instala para o seu usuário. Precisa do runtime `org.gnome.Platform//51` e do `org.gnome.Sdk//51` do Flathub. Para abrir: `flatpak run io.github.eduardo_lima_dev.ConectDroidCam`, ou pelo menu de aplicativos.

## O que vai dentro

- **ffmpeg 9.1 mínimo** (LGPL), compilado a partir do código-fonte pelo próprio manifesto. Só tem o que o app usa: decodificar H.264, escrever em `/dev/videoN` (saída `v4l2`) e gerar a prévia JPEG.
- O app, em `/app/bin`, com `libcdc_ffi.so` ao lado.
- O script auxiliar `linux-webcam-virtual.sh`, em `/app/share/conectdroidcam/linux-webcam-virtual.sh`.
- Permissões: rede (descoberta e conexão), janela (Wayland e X11) e `--device=all`, para as webcams virtuais.

## Publicação no Flathub (cancelada)

O envio ao Flathub foi cancelado em 26/11/2026; o app é distribuído só pelo repositório próprio. Os arquivos abaixo ficam como referência.

O manifesto raiz (`flatpak/io.github.eduardo_lima_dev.ConectDroidCam.yml`) usa o bundle local para builds rápidos de desenvolvimento (`instalar-local.sh` e `release.yml`).

Para o **Flathub**, onde tudo precisa ser compilado offline a partir do código-fonte público:

- O template fonte-a-fonte fica em [`flatpak/flathub/flatpak-flutter.yml`](../flatpak/flathub/flatpak-flutter.yml).
- O gerador e validador (`flatpak-flutter` + `flatpak-builder-lint`) fica em [`scripts/flatpak/preparar-flathub.sh`](../scripts/flatpak/preparar-flathub.sh).
- O passo a passo completo para publicar no `flathub/flathub` está em [`flatpak/flathub/PUBLICAR-NO-FLATHUB.md`](../flatpak/flathub/PUBLICAR-NO-FLATHUB.md).

## Build automático (GitHub Actions)

O workflow [`.github/workflows/release.yml`](../.github/workflows/release.yml) roda:

- a cada PR para a `main`: gera o `ConectDroidCam.flatpak` e o APK como artefatos (o CI, com os testes e validação dos metadados Flatpak, roda pelo `ci.yml`);
- a cada push na `main`: roda o CI, o APK e o Flatpak e, **só se os três passarem**, cria uma release automática `build-N` com os dois arquivos e as notas tiradas dos commits desde a release anterior, e publica o repositório Flatpak no GitHub Pages;
- a cada tag `v*`: anexa o `.flatpak` à release dessa tag.

O APK é assinado com a chave de release e o seu `versionCode` é o mesmo `N` da tag `build-N`; o repositório Flatpak é assinado com a chave GPG. As duas chaves e o que fazer com elas estão em [atualizacoes.md](atualizacoes.md).

## Limitações conhecidas

- A identidade (certificado) e os celulares pareados ficam em `~/.var/app/io.github.eduardo_lima_dev.ConectDroidCam/config`, separados do app de desenvolvimento. Por isso, o primeiro uso do Flatpak pede o pareamento de novo.
- O módulo `v4l2loopback` é do kernel do Linux e precisa estar instalado no sistema hospedeiro; dentro do Flatpak, o app exibe o comando que extrai o `linux-webcam-virtual.sh` empacotado.
