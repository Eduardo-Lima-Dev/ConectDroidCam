# Identidade visual

A logo do ConectDroidCam vem de um único arquivo, [`branding/LogoCDC.png`](../branding/LogoCDC.png) (1254×1254, quadrado arredondado azul-marinho com cantos transparentes). Todos os ícones e imagens do projeto são **gerados** a partir dele, em vez de editados à mão.

## Refazer os ícones

Depois de trocar a logo em `branding/LogoCDC.png`:

```sh
pip install pillow
python3 tools/branding/gerar_icones.py
```

O script grava os arquivos das plataformas, que são versionados. Para só conferir o resultado a olho, sem gravar nada no projeto:

```sh
python3 tools/branding/gerar_icones.py --so-previa --preview /tmp/previa.png
```

A folha de contato mostra o ícone com as máscaras circular e quadrada do Android, o ícone do tema do Android 13, o do iOS, o do macOS e a notificação em tamanho real.

## Onde a logo é usada

| Onde | Arquivos | Observação |
|---|---|---|
| Android: ícone do app | `mipmap-*/ic_launcher.png` | Ícone clássico, para Android antigo e lançadores que não usam o adaptativo |
| Android: ícone adaptativo | `mipmap-anydpi-v26/ic_launcher.xml`, `ic_launcher_foreground.png` | Fundo azul-marinho e a logo dentro da zona segura. O fabricante corta em círculo ou quadrado |
| Android: tema de ícones (13+) | `ic_launcher_monochrome.png` | Silhueta branca; o sistema a pinta com a cor do tema |
| Android: notificações | `drawable-*/ic_stat_cdc.png` | Símbolo da webcam em branco sobre transparente, como o Android exige (veja abaixo) |
| Android: abertura | `drawable*/launch_background.xml`, `launch_logo.png`, `values-v31/styles.xml` | Fundo azul-marinho com a logo no centro |
| iOS | `AppIcon.appiconset`, `LaunchImage.imageset` | Ícones sem transparência, que a Apple exige |
| macOS | `AppIcon.appiconset` | Ícone com margem, porque o macOS não aplica máscara |
| Linux: janela | `assets/branding/app_icon.png` | Carregado pelo `linux/runner/my_application.cc` |
| Linux: menu e barra de tarefas | `packaging/linux/` | Ícones `hicolor` e arquivo `.desktop`, para o empacotamento |
| Dentro do app | `assets/branding/logo.png` e o widget `BrandLogo` | Telas de abertura, de erro, título do painel e tela do computador |

As cores vêm da logo: azul-marinho `#012058` (fundo do ícone e da abertura) e o verde do anel `#62F713` (cor de destaque do tema).

## Por que a notificação não usa a logo inteira

O Android pinta o ícone pequeno da notificação com uma cor só, usando apenas a transparência da imagem. A logo completa (celular, notebook, pinguim, OBS e webcam) vira um borrão a 24 px, o tamanho real. Por isso a notificação usa o **símbolo da webcam com os raios**, recortado da própria logo, que continua legível pequeno.

O app ainda **não envia notificações**. O recurso `ic_stat_cdc` já existe e será usado pela notificação do serviço de transmissão em segundo plano, quando ele existir.

## O que não foi verificado

- **Android:** o APK contém todos os recursos e o app abre no aparelho, mas a aparência do ícone na tela inicial (adaptativo, tema de ícones) não foi conferida por quem usa. Cada fabricante aplica a máscara de um jeito.
- **iOS e macOS:** os arquivos foram gerados nos tamanhos que o `Contents.json` pede, e um teste confere que os do iOS não têm transparência, mas **não foram compilados** (falta um Mac com Xcode). A tela de abertura do iOS mantém o fundo do storyboard, que não foi alterado.
- **Linux:** em X11 a janela anuncia o ícone de 256×256. No **Wayland** o ícone vem do arquivo `.desktop`, que só vale depois de instalado (`packaging/linux/`); rodando direto da pasta de build, a janela pode aparecer sem o ícone.
- O nome do produto no macOS (`PRODUCT_NAME`) continua em minúsculas, porque mudá-lo altera o caminho do pacote.
