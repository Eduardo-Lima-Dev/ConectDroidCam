# Melhorias: correções e funcionalidades novas

Lista das correções e das funcionalidades sugeridas na revisão de 26/11/2026, com o estado de cada uma. Cada item tem um código (por exemplo, `F-PC-4`) para ser pedido depois pelo nome.

**Última atualização:** 26/11/2026.

Legenda: ✅ feito · 🟡 feito em parte · ⬜ não feito · ➖ não precisou.

"Falta validar" quer dizer que o código está pronto e testado com simulações, mas ainda não foi conferido no aparelho ou ambiente de verdade.

## Resumo

| Grupo | Feito | Falta |
|---|---|---|
| Correções de UX (`U-1` a `U-14`) | 13 | 0 (o `U-14` não precisou) |
| Correções de texto (`T-1` a `T-9`) | 9 | 0 |
| Documentação (`D-1` a `D-4`) | 4 | 0 |
| Correções técnicas (`K-1` a `K-3`) | 3 | 0 |
| Funcionalidades do celular (`F-CEL-1` a `F-CEL-7`) | 1 e 1 em parte | 5 |
| Funcionalidades do computador (`F-PC-1` a `F-PC-7`) | 2 | 5 |
| Funcionalidades nos dois (`F-2-1` a `F-2-5`) | 0 | 5 |

## Correções

### Experiência de uso (UX)

| Código | Onde | Correção | Estado |
|---|---|---|---|
| U-1 | Celular | Aviso de pareamento concluído aparecia em vermelho; virou `SnackBar` | ✅ #10 |
| U-2 | PC | Título do cartão seguia "Celular conectado" durante a conexão; agora segue a fase | ✅ #10 |
| U-3 | PC | Status repetido e com IP num lugar e nome no outro | ✅ #10 |
| U-4 | Os dois | Remover pareamento sem confirmação | ✅ #10 |
| U-5 | PC | Lista de celulares pareados com remoção individual | ✅ #10 |
| U-6 | PC | Endereço sem porta usa 47821; aceita IPv6 e nomes de host | ✅ #10 (IPv6 com nome de interface, `fe80::1%wlan0`, pode não resolver) |
| U-7 | PC | Retorno visual ao copiar comandos | ✅ #10 |
| U-8 | PC | Avisos de erro e informação podem ser fechados | ✅ #10 |
| U-9 | Celular | Botão "Abrir configurações" sem permissão de câmera; câmera volta sozinha | ✅ #10, falta validar |
| U-10 | Celular | Permissão de notificação só pedida quando faz sentido | ✅ #10 |
| U-11 | Os dois | Contagem regressiva do código de pareamento | ✅ #10 |
| U-12 | Os dois | Tema segue o do sistema, com cores legíveis no claro | ✅ #10 |
| U-13 | PC | Comando de setup da webcam funciona fora do repositório | ✅ #10 |
| U-14 | PC | Aviso de atualização com comando errado fora do Flatpak | ➖ o aviso já só aparece no Flatpak |

### Textos

| Código | Correção | Estado |
|---|---|---|
| T-1 | Erros técnicos do PC viram frases claras, com "Mostrar detalhes" | ✅ #11 |
| T-2 | Tom padronizado em "Não consegui…" | ✅ #11 |
| T-3 | "já usado antes" virou "pareado" | ✅ #11 |
| T-4 | "Sistema: android" virou "Android" | ✅ #11 |
| T-5 | Celular mostra o nome do computador, não o IP | ✅ #11 |
| T-6 | "Sem rede local" explica o que fazer | ✅ #11 |
| T-7 | Aviso do ffmpeg próprio para o Flatpak | ✅ #11 |
| T-8 | Ajuda do OBS recolhida em "Como usar no OBS" | ✅ #11 |
| T-9 | Erros de câmera do celular explicados (sem "código N") | ✅ #11 |

### Documentação

| Código | Correção | Estado |
|---|---|---|
| D-1 | README com o estado real (pareamento, TLS, prévia) | ✅ #11 |
| D-2 | Roadmap: tabela de fases, Fase 4, ordem recomendada | ✅ #11 |
| D-3 | Metainfo afirma só o que foi testado (OBS) | ✅ #11 |
| D-4 | Flathub marcado como cancelado | ✅ #11 |

### Técnicas com efeito no usuário

| Código | Correção | Estado |
|---|---|---|
| K-1 | ffmpeg do Flatpak com otimizações em assembly | ✅ #11 (compilado e conferido; consumo de CPU não medido) |
| K-2 | Celular reconhecido pela impressão digital quando o IP muda | ✅ #11, falta validar |
| K-3 | Câmera perdida em segundo plano volta sozinha | ✅ #11, falta validar |

## Funcionalidades novas

### Celular (emissor)

| Código | Funcionalidade | Estado |
|---|---|---|
| F-CEL-1 | **Transmissão em segundo plano**: serviço com notificação (Parar, Trocar câmera), CPU e Wi-Fi mantidos acordados | ✅ falta validar no aparelho |
| F-CEL-2 | Tela escura durante a transmissão, para poupar bateria | ⬜ |
| F-CEL-3 | **Controles de câmera**: zoom (pinça, 0,5×/1×/2×, controle deslizante), toque para focar e medir a luz, exposição, travas de exposição e cor, lanterna | 🟡 falta escolher a lente explicitamente (abaixo de 1× já usa a grande-angular quando o aparelho permite) e comandar pelo PC |
| F-CEL-4 | Estabilização de vídeo ligável | ⬜ |
| F-CEL-5 | Aviso de temperatura e bateria, com redução automática de FPS ou resolução | ⬜ |
| F-CEL-6 | Microfone | ⬜ (no roadmap) |
| F-CEL-7 | QR code com o endereço | ⬜ |

### Computador (receptor)

| Código | Funcionalidade | Estado |
|---|---|---|
| F-PC-1 | **Ícone na bandeja**: menu com estado, mostrar janela, iniciar/parar, trocar câmera, desconectar e sair; fechar a janela esconde | ✅ falta validar num ambiente com bandeja. No GNOME puro não há bandeja: fechar com o celular conectado pergunta se o app continua escondido |
| F-PC-2 | **Assistente da primeira execução** (e botão "Verificar o sistema"): ffmpeg, módulo, Secure Boot, webcams, bandeja, dicas de OBS e firewall | ✅ não detecta o OBS em Flatpak nem o firewall (são dicas) |
| F-PC-3 | Ajustes de imagem no PC (espelhar, cortar, brilho e contraste) | ⬜ |
| F-PC-4 | Botão "Pausar imagem" (privacidade) | ⬜ |
| F-PC-5 | Painel de diagnóstico com gráfico e "Copiar relatório" | ⬜ |
| F-PC-6 | Atalhos de teclado globais | ⬜ |
| F-PC-7 | Decodificação por hardware (VA-API) | ⬜ (no roadmap, `cdc-decode`) |

### Nos dois apps

| Código | Funcionalidade | Estado |
|---|---|---|
| F-2-1 | Nome personalizado do aparelho | ⬜ |
| F-2-2 | Perfis salvos (resolução, FPS, câmera) | ⬜ |
| F-2-3 | Tradução pt-BR e inglês | ⬜ (no roadmap) |
| F-2-4 | Tela "Sobre" com versão, licença e links | ⬜ |
| F-2-5 | Indicador de qualidade da conexão | ⬜ |

## Como as funcionalidades feitas funcionam

- **F-CEL-1:** ao iniciar a transmissão, o app sobe o `StreamingService` (tipo câmera). A notificação mostra para quem transmite, a resolução, o FPS e a câmera. A primeira transmissão iniciada no celular pede a permissão de notificação uma única vez.
- **F-CEL-3:** os ajustes ficam no `CameraController` e valem para a prévia e para o vídeo enviado. Trocar de câmera volta tudo ao padrão. Tocar na prévia foca naquele ponto; "Voltar ao foco automático" desfaz. A tela cheia passou a ser um botão próprio, porque o toque na prévia agora foca.
- **F-PC-1:** a bandeja é feita no Rust com o `ksni` (sem dependência em C) e fala com o Dart pela ponte (`tray_start`, `tray_update`, `tray_stop`). O executor GTK virou instância única e repassa o fechamento da janela ao Dart pelo canal `cdc/window`. O Flatpak ganhou `--talk-name=org.kde.StatusNotifierWatcher`.
- **F-PC-2:** aparece uma vez (campo `setupDone` no `receptor.json`; quem já usava o app também o vê uma vez) e depois pelo botão no cabeçalho.
