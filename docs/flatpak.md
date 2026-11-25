# Flatpak do ConectDroidCam

O app do Linux é empacotado como Flatpak, com o id `io.github.eduardo_lima_dev.ConectDroidCam`. O manifesto fica em [`flatpak/io.github.eduardo_lima_dev.ConectDroidCam.yml`](../flatpak/io.github.eduardo_lima_dev.ConectDroidCam.yml).

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

## Publicação no Flathub

O manifesto raiz (`flatpak/io.github.eduardo_lima_dev.ConectDroidCam.yml`) usa o bundle local para builds rápidos de desenvolvimento (`instalar-local.sh` e `release.yml`).

Para o **Flathub**, onde tudo precisa ser compilado offline a partir do código-fonte público:

- O template fonte-a-fonte fica em [`flatpak/flathub/flatpak-flutter.yml`](../flatpak/flathub/flatpak-flutter.yml).
- O gerador e validador (`flatpak-flutter` + `flatpak-builder-lint`) fica em [`scripts/flatpak/preparar-flathub.sh`](../scripts/flatpak/preparar-flathub.sh).
- O passo a passo completo para publicar no `flathub/flathub` está em [`flatpak/flathub/PUBLICAR-NO-FLATHUB.md`](../flatpak/flathub/PUBLICAR-NO-FLATHUB.md).

## Build automático (GitHub Actions)

O workflow [`.github/workflows/release.yml`](../.github/workflows/release.yml) roda:

- a cada PR para a `main`: gera o `ConectDroidCam.flatpak` e o APK como artefatos (o CI, com os testes e validação dos metadados Flatpak, roda pelo `ci.yml`);
- a cada push na `main`: roda o CI, o APK e o Flatpak e, **só se os três passarem**, cria uma release automática `build-N` com os dois arquivos e as notas tiradas dos commits desde a release anterior;
- a cada tag `v*`: anexa o `.flatpak` à release dessa tag.

O APK da release é assinado com a chave de debug enquanto não houver uma chave de release nos segredos do repositório.

## Limitações conhecidas

- A identidade (certificado) e os celulares pareados ficam em `~/.var/app/io.github.eduardo_lima_dev.ConectDroidCam/config`, separados do app de desenvolvimento. Por isso, o primeiro uso do Flatpak pede o pareamento de novo.
- O módulo `v4l2loopback` é do kernel do Linux e precisa estar instalado no sistema hospedeiro; dentro do Flatpak, o app exibe o comando que extrai o `linux-webcam-virtual.sh` empacotado.
