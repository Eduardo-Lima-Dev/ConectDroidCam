#!/usr/bin/env python3
"""Gera os ícones e imagens da marca para todas as plataformas a partir de
`branding/LogoCDC.png`, que é a única fonte da logo.

Uso:
    python3 tools/branding/gerar_icones.py [--preview caminho.png]

Precisa do Pillow (`pip install pillow`). Os arquivos gerados são versionados, então
só é preciso rodar de novo quando a logo mudar.

O que sai, por plataforma:
  Android  ícone clássico, ícone adaptativo (primeiro plano + fundo + monocromático
           para o tema de ícones do Android 13), ícone de notificação e logo da
           tela de abertura
  iOS      AppIcon (sem transparência, como a Apple exige) e LaunchImage
  macOS    AppIcon (com a margem que o macOS espera)
  Linux    ícones hicolor para o menu e a barra de tarefas, e o ícone da janela
  Flutter  logo usada dentro do app
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

RAIZ = Path(__file__).resolve().parents[2]
FONTE = RAIZ / "branding" / "LogoCDC.png"
APP = RAIZ / "apps" / "conectdroidcam"
RES = APP / "android" / "app" / "src" / "main" / "res"
LANCZOS = Image.Resampling.LANCZOS

ID_APP = "io.github.eduardo_lima_dev.ConectDroidCam"

DENSIDADES = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}

gerados: list[Path] = []


def salvar(img: Image.Image, destino: Path) -> None:
    destino.parent.mkdir(parents=True, exist_ok=True)
    img.save(destino, optimize=True)
    gerados.append(destino)


def escrever(destino: Path, texto: str) -> None:
    destino.parent.mkdir(parents=True, exist_ok=True)
    destino.write_text(texto, encoding="utf-8")
    gerados.append(destino)


def carregar() -> Image.Image:
    """Abre a logo e recorta a margem transparente, deixando-a quadrada."""
    img = Image.open(FONTE).convert("RGBA")
    caixa = img.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    if caixa is None:
        sys.exit("a logo está totalmente transparente")
    img = img.crop(caixa)
    lado = max(img.size)
    quadrada = Image.new("RGBA", (lado, lado), (0, 0, 0, 0))
    quadrada.paste(img, ((lado - img.width) // 2, (lado - img.height) // 2))
    return quadrada


def redimensionar(img: Image.Image, lado: int) -> Image.Image:
    return img.resize((lado, lado), LANCZOS)


def cor_de_fundo(img: Image.Image) -> tuple[int, int, int]:
    """Azul-marinho médio de regiões do fundo sem desenho, perto dos cantos."""
    n = img.width
    pontos = []
    for ox, oy in [(0.12, 0.12), (0.88, 0.12), (0.12, 0.88), (0.88, 0.88)]:
        for dx in range(-4, 5):
            for dy in range(-4, 5):
                pontos.append(img.getpixel((int(n * ox) + dx * 6, int(n * oy) + dy * 6)))
    return tuple(round(statistics.mean(p[i] for p in pontos)) for i in range(3))  # type: ignore[return-value]


def cor_verde(img: Image.Image) -> tuple[int, int, int]:
    """Verde do anel: mediana dos pixels bem verdes."""
    dados = img.convert("RGBA").resize((300, 300), LANCZOS).tobytes()
    todos = [tuple(dados[i : i + 4]) for i in range(0, len(dados), 4)]
    px = [p for p in todos if p[3] > 250 and p[1] > 190 and p[0] < 140 and p[2] < 60]
    return tuple(round(statistics.median(p[i] for p in px)) for i in range(3))  # type: ignore[return-value]


def hexa(cor: tuple[int, int, int]) -> str:
    return "#%02X%02X%02X" % cor


def achatar(img: Image.Image, fundo: tuple[int, int, int]) -> Image.Image:
    """Cola a logo sobre um fundo opaco (a Apple não aceita transparência no ícone)."""
    base = Image.new("RGB", img.size, fundo)
    base.paste(img, mask=img.getchannel("A"))
    return base


def com_margem(img: Image.Image, canvas: int, fracao: float) -> Image.Image:
    """Centraliza a logo num canvas transparente, ocupando `fracao` dele."""
    lado = round(canvas * fracao)
    saida = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    saida.paste(redimensionar(img, lado), ((canvas - lado) // 2, (canvas - lado) // 2), redimensionar(img, lado))
    return saida


def silhueta(logo: Image.Image, lado: int = 800) -> Image.Image:
    """Forma branca da logo, em tons de cinza: só os traços claros (branco e verde do
    anel), sem o fundo azul nem a borda do quadrado. Serve ao ícone monocromático e ao
    ícone de notificação, que o Android pinta de uma cor só."""
    im = redimensionar(logo, lado)
    r, g, b, _ = im.split()

    def acima(banda: Image.Image, minimo: int) -> Image.Image:
        return banda.point(lambda v: 255 if v >= minimo else 0)

    def entre(banda: Image.Image, lo: int, hi: int) -> Image.Image:
        return banda.point(lambda v: 255 if lo <= v <= hi else 0)

    branco = ImageChops.multiply(ImageChops.multiply(acima(r, 185), acima(g, 185)), acima(b, 185))
    # O degradê verde da tela do celular tem azul mais alto que o anel; o filtro o exclui.
    verde = ImageChops.multiply(ImageChops.multiply(acima(g, 200), entre(r, 60, 190)), entre(b, 0, 60))
    forma = ImageChops.lighter(branco, verde)

    # Ignora a borda e o brilho do quadrado arredondado.
    interior = Image.new("L", (lado, lado), 0)
    margem = round(lado * 0.07)
    ImageDraw.Draw(interior).rounded_rectangle(
        [margem, margem, lado - margem, lado - margem], radius=round(lado * 0.17), fill=255
    )
    return ImageChops.multiply(forma, interior)


def recortar_forma(forma: Image.Image) -> Image.Image:
    caixa = forma.point(lambda v: 255 if v > 8 else 0).getbbox()
    return forma.crop(caixa) if caixa else forma


def so_webcam(forma: Image.Image) -> Image.Image:
    """Recorta da silhueta só a webcam com os raios, no alto da logo. A logo inteira
    vira um borrão a 24 px; a webcam continua legível e é o símbolo da marca."""
    n = forma.width
    return forma.crop((round(n * 0.40), round(n * 0.02), round(n * 0.60), round(n * 0.32)))


def glifo_branco(forma: Image.Image, canvas: int, ocupa: float, engrossar: int = 0) -> Image.Image:
    """Silhueta branca sobre transparente, centralizada e ocupando `ocupa` do canvas."""
    forma = recortar_forma(forma)
    maior = max(forma.size)
    alvo = round(canvas * ocupa)
    escala = alvo / maior
    # Engrossa antes de reduzir, senão os traços finos somem em ícones pequenos.
    grande = forma.resize((round(forma.width * escala * 4), round(forma.height * escala * 4)), LANCZOS)
    for _ in range(engrossar):
        grande = grande.filter(ImageFilter.MaxFilter(5))
    pequeno = grande.resize((round(forma.width * escala), round(forma.height * escala)), LANCZOS)
    saida = Image.new("RGBA", (canvas, canvas), (255, 255, 255, 0))
    alfa = Image.new("L", (canvas, canvas), 0)
    alfa.paste(pequeno, ((canvas - pequeno.width) // 2, (canvas - pequeno.height) // 2))
    saida.putalpha(alfa)
    return saida


# --------------------------------------------------------------------------- Android


def gerar_android(logo: Image.Image, fundo: tuple[int, int, int], forma: Image.Image) -> None:
    for nome, esc in DENSIDADES.items():
        # Ícone clássico (Android antes do 8 e lançadores que não usam o adaptativo).
        salvar(redimensionar(logo, round(48 * esc)), RES / f"mipmap-{nome}" / "ic_launcher.png")

        # Adaptativo: tela de 108 dp, mas só os 72 dp centrais aparecem de forma garantida,
        # e uma máscara circular corta ainda mais. A logo cabe nessa zona segura.
        lado = round(108 * esc)
        salvar(com_margem(logo, lado, 0.66), RES / f"mipmap-{nome}" / "ic_launcher_foreground.png")
        salvar(glifo_branco(forma, lado, 0.50, engrossar=1), RES / f"mipmap-{nome}" / "ic_launcher_monochrome.png")

        # Notificação: 24 dp, branco sobre transparente, como o Android exige.
        px_notif = round(24 * esc)
        # Em telas pequenas o traço já sai grosso demais: engrossa menos.
        salvar(
            glifo_branco(so_webcam(forma), px_notif, 0.90, engrossar=2 if px_notif >= 48 else 1),
            RES / f"drawable-{nome}" / "ic_stat_cdc.png",
        )

    salvar(redimensionar(logo, 384), RES / "drawable-nodpi" / "launch_logo.png")

    cor = hexa(fundo)
    escrever(
        RES / "values" / "ic_launcher_background.xml",
        f"""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- Azul-marinho da logo: fundo do ícone adaptativo e da tela de abertura. -->
    <color name="ic_launcher_background">{cor}</color>
    <color name="cdc_navy">{cor}</color>
</resources>
""",
    )
    escrever(
        RES / "mipmap-anydpi-v26" / "ic_launcher.xml",
        """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <!-- Tema de ícones do Android 13: o sistema pinta esta forma com a cor do tema. -->
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
""",
    )

    abertura = """<?xml version="1.0" encoding="utf-8"?>
<!-- Tela de abertura: fundo azul-marinho com a logo no centro. -->
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@color/cdc_navy" />
    <item>
        <bitmap
            android:gravity="center"
            android:src="@drawable/launch_logo" />
    </item>
</layer-list>
"""
    escrever(RES / "drawable" / "launch_background.xml", abertura)
    escrever(RES / "drawable-v21" / "launch_background.xml", abertura)

    # Android 12 em diante desenha a abertura sozinho (ícone do app sobre uma cor).
    for qualificador, pai in [("values-v31", "Light"), ("values-night-v31", "Black")]:
        escrever(
            RES / qualificador / "styles.xml",
            f"""<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.{pai}.NoTitleBar">
        <item name="android:windowBackground">@drawable/launch_background</item>
        <item name="android:windowSplashScreenBackground">@color/cdc_navy</item>
    </style>
</resources>
""",
        )


# --------------------------------------------------------------------------- iOS


def gerar_ios(logo: Image.Image, fundo: tuple[int, int, int]) -> None:
    pasta = APP / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    contents = json.loads((pasta / "Contents.json").read_text(encoding="utf-8"))
    base = achatar(logo, fundo)
    for item in contents["images"]:
        lado_pt = float(item["size"].split("x")[0])
        escala = int(item["scale"].rstrip("x"))
        px = round(lado_pt * escala)
        salvar(base.resize((px, px), LANCZOS), pasta / item["filename"])

    # LaunchImage: a logo no centro (o fundo vem do storyboard).
    lancamento = APP / "ios" / "Runner" / "Assets.xcassets" / "LaunchImage.imageset"
    for arquivo, px in [("LaunchImage.png", 128), ("LaunchImage@2x.png", 256), ("LaunchImage@3x.png", 384)]:
        salvar(redimensionar(logo, px), lancamento / arquivo)


# --------------------------------------------------------------------------- macOS


def gerar_macos(logo: Image.Image) -> None:
    pasta = APP / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    # O macOS não aplica máscara: o ícone traz a própria forma, com cerca de 10% de margem.
    for px in (16, 32, 64, 128, 256, 512, 1024):
        salvar(com_margem(logo, px, 0.82), pasta / f"app_icon_{px}.png")


# --------------------------------------------------------------------------- Linux e app


def gerar_linux(logo: Image.Image) -> None:
    base = RAIZ / "packaging" / "linux" / "icons" / "hicolor"
    for px in (16, 22, 24, 32, 48, 64, 128, 256, 512):
        salvar(redimensionar(logo, px), base / f"{px}x{px}" / "apps" / f"{ID_APP}.png")

    desktop = f"""[Desktop Entry]
Type=Application
Name=ConectDroidCam
GenericName=Phone camera as webcam
GenericName[pt_BR]=Câmera do celular como webcam
Comment=Use your phone camera as a webcam on your computer
Comment[pt_BR]=Use a câmera do celular como webcam no computador
Exec=conectdroidcam
Icon={ID_APP}
Terminal=false
Categories=AudioVideo;Video;
Keywords=webcam;camera;phone;android;obs;
Keywords[pt_BR]=webcam;camera;celular;android;obs;
StartupWMClass={ID_APP}
"""
    escrever(RAIZ / "packaging" / "linux" / f"{ID_APP}.desktop", desktop)
    escrever(RAIZ / "flatpak" / f"{ID_APP}.desktop", desktop)


def gerar_flutter(logo: Image.Image) -> None:
    pasta = APP / "assets" / "branding"
    salvar(redimensionar(logo, 512), pasta / "logo.png")
    # Ícone da janela no Linux (carregado pelo runner GTK).
    salvar(redimensionar(logo, 256), pasta / "app_icon.png")


# --------------------------------------------------------------------------- prévia


def previa(logo: Image.Image, fundo: tuple[int, int, int], forma: Image.Image, destino: Path) -> None:
    """Folha de contato para conferir os ícones a olho, com as máscaras do Android."""
    celula, margem = 220, 16
    itens: list[tuple[str, Image.Image]] = []

    def mascarar(img: Image.Image, formato: str) -> Image.Image:
        lado = img.width
        m = Image.new("L", (lado, lado), 0)
        d = ImageDraw.Draw(m)
        if formato == "circulo":
            d.ellipse([0, 0, lado - 1, lado - 1], fill=255)
        else:
            d.rounded_rectangle([0, 0, lado - 1, lado - 1], radius=round(lado * 0.22), fill=255)
        saida = Image.new("RGBA", (lado, lado), (0, 0, 0, 0))
        saida.paste(img, mask=m)
        return saida

    # O Android mostra só a janela central de 72 dp, de uma tela de 108 dp.
    adaptativo = Image.new("RGBA", (432, 432), fundo + (255,))
    adaptativo.alpha_composite(com_margem(logo, 432, 0.66))
    janela = adaptativo.crop((72, 72, 360, 360))
    itens.append(("Android circular", mascarar(redimensionar(janela, celula), "circulo")))
    itens.append(("Android quadrado", mascarar(redimensionar(janela, celula), "quadrado")))
    itens.append(("Android classico", redimensionar(logo, celula)))

    mono = Image.new("RGBA", (432, 432), (60, 60, 70, 255))
    mono.alpha_composite(glifo_branco(forma, 432, 0.50, engrossar=1))
    itens.append(("Tema de icones", mascarar(redimensionar(mono.crop((72, 72, 360, 360)), celula), "circulo")))

    itens.append(("iOS (sem alfa)", mascarar(redimensionar(achatar(logo, fundo).convert("RGBA"), celula), "quadrado")))
    itens.append(("macOS", redimensionar(com_margem(logo, 1024, 0.82), celula)))

    # Notificação: tamanhos reais, ampliados sem suavizar, sobre a barra escura do Android.
    for dp in (24,):
        for esc in (1, 2, 4):
            g = glifo_branco(so_webcam(forma), dp * esc, 0.90, engrossar=2)
            fundo_barra = Image.new("RGBA", g.size, (40, 40, 48, 255))
            fundo_barra.alpha_composite(g)
            itens.append((f"Notificacao {dp * esc}px", fundo_barra.resize((celula, celula), Image.Resampling.NEAREST)))

    colunas = 5
    linhas = -(-len(itens) // colunas)
    folha = Image.new("RGBA", (colunas * (celula + margem) + margem, linhas * (celula + margem + 24) + margem), (236, 236, 240, 255))
    d = ImageDraw.Draw(folha)
    for i, (rotulo, img) in enumerate(itens):
        x = margem + (i % colunas) * (celula + margem)
        y = margem + (i // colunas) * (celula + margem + 24)
        folha.alpha_composite(img.convert("RGBA"), (x, y))
        d.text((x, y + celula + 4), rotulo, fill=(30, 30, 40, 255))
    destino.parent.mkdir(parents=True, exist_ok=True)
    folha.convert("RGB").save(destino)
    print(f"prévia: {destino}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--preview", type=Path, help="salva uma folha de contato para conferir os ícones")
    ap.add_argument("--so-previa", action="store_true", help="não grava nenhum arquivo do projeto")
    args = ap.parse_args()

    if not FONTE.exists():
        sys.exit(f"logo não encontrada: {FONTE}")

    logo = carregar()
    fundo = cor_de_fundo(logo)
    verde = cor_verde(logo)
    forma = silhueta(logo)
    print(f"logo {logo.size[0]}×{logo.size[1]} · fundo {hexa(fundo)} · verde {hexa(verde)}")

    if args.preview:
        previa(logo, fundo, forma, args.preview)
    if args.so_previa:
        return

    gerar_android(logo, fundo, forma)
    gerar_ios(logo, fundo)
    gerar_macos(logo)
    gerar_linux(logo)
    gerar_flutter(logo)
    print(f"{len(gerados)} arquivos gerados")


if __name__ == "__main__":
    main()
