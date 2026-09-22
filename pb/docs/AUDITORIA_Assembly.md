# Auditoria de pb/assembly — 21/09/2026

## Fluxo real

1. `camera_capture.py` busca uma imagem HTTP, aplica crop opcional e usa ffmpeg para gerar GRAY8 de 160×120. Empacota 48 bytes de cabeçalho BOWL e 19.200 pixels. Session ID e tempo monotônico ficam no cabeçalho e no JSON, mas não fazem parte da identidade SPI.
2. `spi_image_client.s` é Linux AArch64 sem libc. Valida tamanho/cabeçalho e threshold de 0 a 255. Configura SPI modo 0, 8 bits, 100 kHz. Envia GET_INFO, BEGIN, 19 blocos (18×1024 + 768), END e GET_RESULT: 23 comandos com sequência 0–22 e CRC16/CCITT-FALSE.
3. Cada comando usa uma transação; outra transação de 37 bytes começa com F0 e lê a resposta de 32 bytes a partir do offset 5. O Assembly verifica CRC, versão, operação, frame ID, sequência e status. Faz até 100 consultas por comando, com pausa de 1 ms além do tempo da transferência. Não retransmite o comando.
4. `pb/verilog/assessment/src/spi_image/gray_bowl_detector.v` conta pixels estritamente maiores que o threshold: mais de 9.600 claros = empty; menos = not_empty; empate = unknown. Isso é uma heurística de luminosidade e depende de ROI e calibração.
5. O Assembly grava a resposta binária; Python valida novamente e publica JSON por substituição atômica. Falhas publicam valid=false e unknown. Um lock impede dois produtores usando o mesmo caminho de saída.
6. `bowl_notifier.py` aceita apenas resultados recentes e frames distintos. Confirma vazio, notifica uma vez por episódio e rearma após not_empty. Unknown/inválido limpa contadores sem rearmar. É dry-run por padrão. Com --send, persiste pending antes de chamar Twilio; uma exceção vira unknown e não dispara retry automático. Accepted não comprova entrega ao destinatário.

## Achados

| Prioridade | Local | Evidência e consequência |
|---|---|---|
| Alta | `spi_diag.py`, build_command | Emite magic `57 42`; Assembly e RTL usam `42 57`. O GET_INFO do diagnóstico é rejeitado mesmo com hardware correto. Além disso, o script retorna 0 quando recebe status de erro e não valida identidade completa nem capacidades GET_INFO. Corrigir antes de usá-lo como critério de aprovação. |
| Alta | `tests/test_assembly_client.py`, main | Procura `ROOT.parent/verilog_tp4/assessment/sim/build`; neste projeto o caminho é `pb/verilog/...`. O teste passa e omite silenciosamente os arquivos de replay. O runner RTL também permite pular replay, portanto passar as suítes separadas não comprova integração. |
| Alta | `twilio_2FA_recovery_code.txt` e `.gitignore` | O arquivo de recuperação existe e `git ls-files` confirma rastreamento. Conteúdo não foi aberto. As regras atuais são voltadas a tp*, não pb. Remover do índice e trocar o código se ainda válido; apenas adicionar ignore não elimina histórico nem rastreamento. |
| Média | `README.md` | Descreve câmera OV2640, GPIO e gpio_poll.s, enquanto pb usa câmera HTTP e SPI. Seguir o README atual pode levar à montagem e execução erradas. |
| Média | `bowl_notifier.py`, persistência | Persiste episódio, mas não último frame/capture observado. Ao reiniciar pode processar de novo um frame ainda recente, incluindo um not_empty antigo que rearma o episódio. Testar restart com confirmação >1 e estado pendente antes de envio real. |
| Média | `wire_check.py` | Não verifica retorno de pinctrl set/get e restaura sempre a função solicitada (default a0), não a configuração anterior. A docstring atribui restauração ao kernel, mas é feita no finally. Usar somente em bancada isolada, sem a FPGA dirigindo o pino do teste. |
| Baixa | `make_test_frame.py` | `level & 0xFF` converte valores fora de 0–255 silenciosamente; frame ID fora de u32 gera exceção. Validar argumentos evita fixtures diferentes do esperado. |

## Validação executada

- `python -m unittest discover -s pb/assembly/tests -p test_pipeline.py -v`: **6/6 passaram**.
- Ubuntu 20.04 WSL: `make PREFIX=aarch64-linux-gnu test-assembly`: **passou**, compilação GNU AArch64 e execução QEMU; 23 pacotes, 19.200 pixels, CRC/layout e rejeição de entrada.
- Reprodução Python da assinatura de `spi_diag.build_command`: **5742**, divergente de **4257** esperado pelo RTL.
- RTL/replay: **não validado nesta auditoria**. O script PowerShell foi bloqueado pela política de execução; chamadas diretas ao Icarus falharam ao criar o artefato de saída, inclusive após tentativa fora do ambiente restrito. A geração manual do frame também encontrou falha de caminho no Windows. Isso não demonstra falha funcional do RTL.
- Câmera, ioctl/spidev, cabeamento, FPGA física e entrega WhatsApp: **não executados**.

O teste QEMU usa --emit: não exercita configuração ioctl, polling, recepção nem tratamento de erros do dispositivo. O replay RTL, quando executado, exercita os comandos gerados, mas também não executa o caminho de recepção do Assembly.

## Roteiro de ponta a ponta

### 1. Preparação e testes offline

Corrigir magic do diagnóstico e caminho do replay. Executar em Linux AArch64 ou Linux x86 com binutils AArch64 e qemu-aarch64. No Pi, o sistema operacional precisa ser de 64 bits.

```sh
cd pb/assembly
make test
make PREFIX=aarch64-linux-gnu test-assembly  # Linux x86; no Pi usar make test-assembly
```

Depois executar `pb/verilog/assessment/sim/run_spi_tests.ps1` em ambiente PowerShell autorizado com Icarus. Exigir tanto PASS da suíte RTL quanto PASS do replay, sem aceitar a mensagem de skip. O replay esperado tem 19.630 bytes, 23 comandos e resultado empty com 9.601 claros. Não reutilizar arquivo antigo como evidência de build atual.

### 2. Raspberry e FPGA

Confirmar bitstream correspondente a `spi_image_top`, constraints da placa, SPI habilitado e acesso a `/dev/spidev0.0`. Confirmar MOSI/MISO/SCLK/CS/GND pelo arquivo CST do projeto. Executar `python3 spi_diag.py` somente após corrigir a assinatura e exigir GET_INFO sem erro, versão 1, capacidade >=1024 e identificador esperado.

```sh
cd pb/assembly
make
python3 make_test_frame.py empty /tmp/audit_empty.bowl
python3 make_test_frame.py full /tmp/audit_full.bowl
build/bin/spi_image_client /tmp/audit_empty.bowl /tmp/audit_empty.reply 100 /dev/spidev0.0
build/bin/spi_image_client /tmp/audit_full.bowl /tmp/audit_full.reply 100 /dev/spidev0.0
python3 -c "from pathlib import Path; from camera_capture import parse_reply; print(parse_reply(Path('/tmp/audit_empty.reply').read_bytes(),1)); print(parse_reply(Path('/tmp/audit_full.reply').read_bytes(),1))"
```

Saídas devem ser novas: o Assembly usa O_EXCL e recusa sobrescrever arquivos. Esperar empty/19200 claros e not_empty/0 claros, respectivamente, ambos válidos. Usar nomes novos ao repetir.

### 3. Câmera até JSON

No Pi, com ffmpeg disponível, substituir URL abaixo pelo endpoint de snapshot verificado:

```sh
python3 camera_capture.py --url 'URL_DO_SNAPSHOT' --threshold 100 --once
```

Esperar exit 0, valid=true, pixels_total=19200 e estado coerente com a imagem. Threshold 100 é ponto de teste, não calibração comprovada. Repetir com pote cheio/vazio e ROI consistente. Em URL indisponível ou SPI com erro, esperar exit 1 e JSON novo inválido/unknown, sem reaproveitar sucesso anterior.

### 4. Política de notificação em dry-run

Executar a captura continuamente (sem --once) e, em outro terminal:

```sh
python3 bowl_notifier.py --confirm 3 --rearm 2
```

Sequência de aceite: 3 frames vazios distintos → um notify; vazio persistente → nenhum novo notify; 2 frames cheios → rearm; 3 novos vazios → um novo notify. Frame repetido, inválido, empate ou mais velho que 10 segundos não pode notificar. Reiniciar processos e simular interrupção no meio do frame também precisa ser verificado. Se uma recepção SPI ficou aberta, o próximo BEGIN a rejeita/aborta; um ciclo posterior pode recuperar.

### 5. Envio real, em teste separado

Somente após os passos anteriores, configurar dependências python-dotenv/twilio e variáveis TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_WHATSAPP_FROM e TWILIO_WHATSAPP_TO (TWILIO_CONTENT_SID opcional). Habilitar --send explicitamente em um teste autorizado. Verificar SID/status persistido e recebimento no aparelho; testar reinício sem duplicar episódio. Nenhuma mensagem foi enviada nesta auditoria.

## Cobertura ainda necessária

Testes de integração com HTTP e ffmpeg; caminho live do Assembly; CRC/status/identidade de replies adversos; timeout e recuperação de frame parcial; limites 0/255 e empate; persistência/reinício do notifier e falhas do provedor. As seis unidades Python atuais cobrem funções e política, não o fluxo completo entre processos.

Fontes funcionais não foram alteradas nesta auditoria. Foram produzidos artefatos de build/teste e este relatório; alterações preexistentes do repositório foram preservadas.
