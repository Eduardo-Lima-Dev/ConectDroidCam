# Flatpak do ConectDroidCam

O app do Linux é empacotado como Flatpak, com o id `dev.eduardolima.conectdroidcam`. O manifesto fica em [`flatpak/dev.eduardolima.conectdroidcam.yml`](../flatpak/dev.eduardolima.conectdroidcam.yml).

## Instalar localmente (sem sudo)

```sh
scripts/flatpak/instalar-local.sh
```

O script gera o bundle de release (`flutter build linux --release`), monta o Flatpak com `org.flatpak.Builder` e instala para o seu usuário. Precisa do runtime `org.gnome.Platform//51` e do `org.gnome.Sdk//51` do Flathub. Para abrir: `flatpak run dev.eduardolima.conectdroidcam`, ou pelo menu de aplicativos.

## O que vai dentro

- **ffmpeg 9.1 mínimo**, compilado a partir do código-fonte pelo próprio manifesto. Só tem o que o app usa: decodificar H.264, escrever em `/dev/videoN` (saída `v4l2`) e gerar a prévia JPEG.
- O app, em `/app/bin`, com `libcdc_ffi.so` ao lado.
- Permissões: rede (descoberta e conexão), janela (Wayland e X11) e `--device=all`, para as webcams virtuais.

## Build automático (GitHub Actions)

O workflow [`.github/workflows/flatpak.yml`](../.github/workflows/flatpak.yml) roda:

- a cada push na `main` e a cada PR para a `main`: gera o `ConectDroidCam.flatpak` e o publica como artefato do workflow (aba **Actions**, no item da execução);
- a cada tag `v*`: anexa o mesmo arquivo à GitHub Release.

Enquanto o repositório for privado, só quem tem acesso consegue baixar o artefato ou a release.

## Limitações conhecidas

- A identidade (certificado) e os celulares pareados ficam em `~/.var/app/dev.eduardolima.conectdroidcam/config`, separados do app de desenvolvimento. Por isso, o primeiro uso do Flatpak pede o pareamento de novo.
- O bundle é montado a partir do que foi compilado fora do Flatpak. Para publicar no Flathub, o build precisa ser feito inteiro dentro do manifesto, a partir do código-fonte público.
