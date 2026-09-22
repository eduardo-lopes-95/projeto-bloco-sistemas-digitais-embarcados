# Auditoria de pb/verilog — 21/09/2026

## Resultado

O fluxo nominal Assembly → pacotes SPI → RTL → classificação passou em simulação. Não foi identificada falha funcional nesse fluxo exercitado. Existem lacunas na automação dos testes e na comprovação de funcionamento físico. Não foram alterados os fontes funcionais.

| Verificação executada | Resultado |
|---|---|
| Icarus Verilog, `tb_spi_image`, parâmetros padrão | PASS: 31 respostas com CRC; maioria, empate, persistência e erros |
| Mesmo testbench, `HALF_PERIOD_NS=5000` | PASS: mesmas 31 respostas com SCLK de 100 kHz |
| QEMU AArch64 executando `spi_image_client --emit` e replay em `tb_assembly_replay` | PASS: 23 comandos, 19.200 pixels, 9.601 claros → empty |
| Síntese, place-and-route, utilização e timing Gowin | Não executados; ferramentas não localizadas no PATH |
| Placa, sinais elétricos, câmera e notificação | Não executados |

Nesta auditoria foi possível superar a limitação de geração de artefatos descrita na auditoria anterior de Assembly: o Icarus usou arquivos em TEMP; o Assembly gerou os bytes em temporários Linux e os bytes foram repassados ao replay. Isso não corrige o caminho desatualizado do gerador original.

## Achados por prioridade

### Alta — replay opcional pode dar uma aprovação incompleta

`assessment/sim/run_spi_tests.ps1` termina normalmente se `assembly_commands.hex` estiver ausente. O gerador `pb/assembly/tests/test_assembly_client.py` procura `verilog_tp4`, não `verilog`. Assim, o fluxo automatizado atual permite aprovar só a suíte de 8 pixels e omitir a integração de 19.200 pixels. Também não verifica se o arquivo de replay corresponde ao build atual.

Correção proposta: ajustar o caminho, gerar a fixture a cada execução integrada e tornar sua ausência um erro nesse modo. Manter um modo explicitamente unitário se desejado.

### Média — resultado válido não significa resultado recente

`gray_bowl_detector.v` preserva `result_valid`, contagens e estado no BEGIN. `spi_image_top.v` deriva `O_alert` diretamente desse snapshot. Não existe watchdog de recepção nem validade temporal. Se o host parar no meio do frame, um alerta anterior pode permanecer indefinidamente. Isso é coerente com a intenção de preservar o último resultado, mas não permite usar os pinos isoladamente como prova de uma observação atual.

GET_RESULT é recusado enquanto `frame_open=1`. Um novo BEGIN nesse estado rejeita/aborta a recepção; um BEGIN posterior pode iniciar novamente. O supervisor Python protege as notificações com validade e idade do JSON, mas essa proteção não existe nos pinos da FPGA.

### Média — reset e temporização física ainda precisam de comprovação

Os três módulos usam diretamente `I_rst_n` como reset assíncrono, inclusive na liberação; não há sincronizador de desativação do reset. O SDC exclui o reset da análise. Simulações ideais não verificam recuperação/remoção ou metastabilidade ao soltar o botão.

SCLK, CS e MOSI atravessam registradores de sincronização, mas o SDC remove a análise de entrada SPI e de saída MISO. Portanto, um relatório sem violações não prova setup/hold SPI. Verificar implementação dos sincronizadores e medir sinais na bancada. Isso é uma lacuna de comprovação, não uma falha física reproduzida nesta auditoria.

### Média — os testes ainda não representam todos os detalhes do master real

Os testbenches acrescentam 600 ns entre bytes, dão folga antes/depois de CS e amostram MISO 100 ns após subir SCLK. O master real pode enviar bytes contínuos e amostra conforme sua implementação SPI. A suíte padrão usa meia fase de 600 ns (~833 kHz dentro de cada byte), não os 100 kHz do Assembly; a execução adicional a 100 kHz passou, mantendo as demais folgas.

Ainda faltam testes com bytes contínuos, amostragem na borda, variação de fase entre clocks, leitura durante processamento, reset durante comando e mínimos declarados de setup/hold de CS. Não aumentar a frequência física com base apenas no PASS atual.

### Baixa — verificações do replay são parciais

`tb_assembly_replay.v` fixa 19.630 bytes e a classificação esperada em vez de consumir o arquivo `.size`. Verifica CRC, status, opcode e byte baixo da sequência, mas não toda a identidade/reservados/capacidades/offset de cada resposta. A mensagem final diz 23 pacotes sem uma asserção explícita `count==23`. Os checks finais usam comparações que não rejeitam todos os valores X de forma explícita.

Melhoria proposta: validar tamanho e quantidade, frame ID completo, sequência completa, magic/versão, offsets, campos reservados e ausência de X; incluir cheio e empate em frames completos. O replay não executa o caminho live de leitura/ioctl do Assembly: esse trecho ainda precisa da placa ou de uma camada de emulação específica.

### Dependência externa já confirmada — diagnóstico SPI incorreto

O RTL espera bytes `42 57` no comando. `pb/assembly/spi_diag.py` envia `57 42`. Corrigir o diagnóstico antes de usá-lo para julgar o hardware. O Assembly principal envia os bytes corretos, conforme replay aprovado.

## Como os módulos funcionam

### spi_slave_mode0.v — camada de bits/bytes

- SPI modo 0, MSB primeiro. Detecta as bordas de SCLK no clock interno; recebe MOSI nas subidas e atualiza MISO nas descidas detectadas.
- Sincroniza SCLK/CS/MOSI; gera pulsos `selected`, `deselected` e `rx_valid`, índice de byte e indicação de byte incompleto.
- MISO fica em alta impedância com CS físico alto, independentemente da latência do sincronizador.
- O contrato declarado requer meia fase SCLK e setup/hold CS de pelo menos 8 clocks internos: aproximadamente 296 ns com 27 MHz. Os 100 kHz dão 5 µs por meia fase, mas setup/hold de CS devem ser verificados separadamente.

### spi_image_top.v — protocolo e controle

Recebe o pacote inteiro, verifica enquadramento e CRC após CS subir e só então entrega pixels ao detector. Usa buffer de 1.024 bytes, não framebuffer de imagem completa. Cabeçalho BEGIN tem armazenamento separado.

Cabeçalho de comando: magic BW (2 bytes), versão (1), opcode (1), frame ID (4), sequência (2), comprimento (2), offset (4); payload variável; CRC (2). Campos numéricos little-endian. CRC16/CCITT-FALSE, inicial FFFF, polinômio 1021.

| Opcode | Operação | Comportamento |
|---|---|---|
| 01 | GET_INFO | Retorna identificador 424F574C, bloco máximo 1024 e versão/capacidade 1 |
| 10 | BEGIN | Valida dimensões, GRAY8, reservados e total; captura threshold e frame ID |
| 11 | Bloco | Exige frame aberto, ID, próxima sequência, offset e limite corretos |
| 12 | END | Exige todos os pixels; aguarda atualização do detector antes da resposta |
| 13 | GET_RESULT | Exige snapshot válido, frame fechado e ID correspondente; ecoa sequência recebida |
| 14 | ABORT | Fecha recepção e invalida o resultado |

O bloco percorre READ_PIXEL → LOAD_PIXEL → EMIT_PIXEL, acomodando leitura síncrona da RAM. FINISH_BLOCK atualiza offset e ACK. Um bloco de 1.024 pixels custa aproximadamente 3.072 clocks para consumo, mais controle e CRC: cerca de 115 µs a 27 MHz. Essa é estimativa por ciclos do RTL, não medição na placa.

Respostas são montadas em `draft_mem`, recebem CRC e são publicadas em `resp_mem`. Cada nova transação captura um snapshot em `snap_mem`: uma leitura iniciada cedo pode retornar a resposta anterior inteira, sem mistura. O cliente precisa comparar opcode, ID e sequência e consultar novamente, como faz o Assembly.

Durante processamento, comandos novos são ignorados (`ignore_command`); não existe resposta BUSY explícita de status 1. Leituras F0 continuam possíveis. O protocolo exige um comando por vez.

Leitura: nova transação com F0 e 36 bytes dummy. Resposta de 32 bytes nos offsets 5–36, magic BR, versão, opcode, ID, sequência, status, indicação de resultado, estado, reservados, total, claros, próximo offset, código de erro e CRC.

Status usados: 0 sucesso, 2 erro. Códigos: 1 formato, 2 CRC, 3 ordem/parâmetros, 4 resultado/frame inválido, 5 opcode desconhecido. A maioria das rejeições aborta o frame e invalida o detector; GET_RESULT indisponível retorna erro sem esse aborto.

### gray_bowl_detector.v — classificação

No início captura threshold e ID, zera contadores de trabalho e preserva snapshot anterior. Cada pixel conta como claro somente se `pixel_gray > threshold`.

Com 19.200 pixels:

| Claros | Estado | O_alert com resultado válido |
|---|---|---|
| 0–9.599 | 0 / not_empty | 0 |
| 9.600 | 2 / unknown | 0 |
| 9.601–19.200 | 1 / empty | 1 |

END com contagem errada ou pixel simultâneo invalida. O pipeline do top separa o último pixel de END e espera a publicação do detector. O replay usa justamente o último pixel para desempatar 9.600 contra 9.599, verificando esse limite.

Isso classifica luminosidade, não reconhece ração semanticamente; câmera, iluminação, crop e threshold precisam ser calibrados.

## Projeto e pinagem declarada

`assessment.gprj` inclui somente os três RTL e os CST/SDC SPI, para GW1NSR-LV4CQN48PC6/I5. Não há captura OV2640 nem HDMI nesse projeto. O único candidato estrutural a top é `spi_image_top`.

| Sinal | Pino de encapsulamento no CST | Correspondência Raspberry descrita no CST |
|---|---|---|
| I_clk | 45 | Oscilador local 27 MHz |
| I_rst_n | 14 | Botão local ativo baixo |
| I_spi_cs_n | 40 | Pino físico 24 / CE0 |
| I_spi_sclk | 41 | Pino físico 23 / SCLK |
| I_spi_mosi | 42 | Pino físico 19 / MOSI |
| O_spi_miso | 43 | Pino físico 21 / MISO |
| O_alert | 39 | Saída de status |
| O_result_valid | 44 | Saída de status |

São números do encapsulamento, não posições do conector da Tang. O arquivo declara SPI em banco de 3,3 V e reset em 1,8 V. Esta auditoria conferiu a configuração local, não validou essas correspondências contra o esquema físico da revisão da placa. Confirmar esquema, conector e GND comum antes da ligação.

## Roteiro de teste de ponta a ponta

1. **Automação:** corrigir caminho do replay e magic do diagnóstico. Recompilar Assembly, gerar fixture atual e exigir PASS de unidade e replay. No Icarus, usar `-Ptb_spi_image.HALF_PERIOD_NS=5000` para repetir a suíte a 100 kHz. Em PowerShell, passar essa opção entre aspas.
2. **Implementação FPGA:** selecionar `spi_image_top`, sintetizar e executar place-and-route. Conferir BSRAM realmente inferida para payload, recursos, clock de 27 MHz, pinos/bancos, warnings e timing. Arquitetura de RAM síncrona no fonte não comprova inferência no resultado final. Gravar exatamente esse bitstream e testar reset/alta impedância de MISO.
3. **SPI físico:** confirmar modo 0, 8 bits, 100 kHz, uma transação por comando e CS desativado entre comando e leitura. Medir SCLK/MOSI/MISO/CS; exigir GET_INFO com identidade, capacidade e CRC válidos.
4. **Imagens sintéticas:** executar Assembly com 19.200 pixels escuros, claros e mistos. Threshold 100: todos 0 → not_empty/0 claros; todos 255 → empty/19200; 9600 pixels 101 e 9600 pixels 100 → unknown; 9601 pixels 101 → empty. Validar resposta completa por `camera_capture.parse_reply`, não apenas pinos.
5. **Falhas/recuperação:** CRC incorreto, ID/sequência/offset errados, frame curto, bloco duplicado, tamanho >1024, interrupção e reset no meio do frame. Exigir ausência de resultado novo válido e recuperação com frame novo. Testar especificamente BEGIN após recepção abandonada.
6. **Câmera e JSON:** executar `camera_capture.py --once` com snapshot verificado; calibrar ROI/threshold com pote cheio/vazio. Repetir continuamente e conferir IDs, timestamps, contagens e erros. Desconexão não pode reutilizar sucesso anterior no JSON.
7. **Notificação:** usar primeiro `bowl_notifier.py` em dry-run. Verificar confirmação por frames distintos, um evento por episódio, rearm após cheio e silêncio em empate/erro/dado antigo. Envio real fica em etapa separada explicitamente autorizada.

Critério de conclusão: simulação aprovada, implementação com recursos/timing conferidos, resposta real validada pelo Assembly/Python para a matriz acima e comportamento correto da política de notificação. O PASS do replay sozinho não equivale a ponta a ponta físico.
