# Relatório de integração, correções e teste de fim a fim

**Projeto:** monitoramento de pote de ração com câmera IP, Raspberry Pi e Tang Nano 4K  
**Data:** 22 de setembro de 2026  
**Ambiente de execução informado:** Raspberry em `/home/pi/pb`, câmera de celular com IP Webcam e FPGA conectada por SPI  
**Evidência principal:** [log de execução fornecido pelo usuário](evidencias/teste_fim_a_fim_2026-09-22.txt)

## 1. Resultado obtido e alcance da validação

O teste apresentado fornece evidência de funcionamento do caminho **câmera → Raspberry → cliente Assembly → FPGA → resultado JSON**. Após falhas de acesso à câmera, o serviço conseguiu obter uma imagem, convertê-la em 19.200 pixels GRAY8 e publicar classificações válidas. O usuário informou ter experimentado um pote sem ração e um pote com ração de cachorro.

Foram analisados **17 registros JSON**, todos com `valid=true`, `pixels_total=19200` e `error=NONE`. O primeiro trecho contém cinco classificações `empty`; o segundo contém 11 `not_empty` e uma `empty`. Esses resultados são compatíveis com as duas condições relatadas, mas o log não marca o instante exato de colocação ou retirada da ração. Portanto, não é possível calcular acurácia ou atribuir um rótulo físico independente a cada frame.

O trecho fornecido **não comprova envio ou entrega de WhatsApp**, nem inicialização após um desligamento completo das placas. Ele também não contém relatório de síntese, timing ou medição elétrica. A integração de captura e classificação foi exercitada; a aceitação completa, incluindo notificação e boot a frio, ainda requer evidências adicionais.

## 2. Arquitetura em funcionamento

```text
Celular / IP Webcam — servidor de fotografia HTTP
                      ↓ Raspberry solicita um snapshot
camera_capture.py — crop opcional, ffmpeg, GRAY8 160 × 120
                      ↓ arquivo BOWL: cabeçalho + 19.200 pixels
spi_image_client.s — Linux AArch64, SPI modo 0, 8 bits, 100 kHz
                      ↓ comandos com identificação, sequência e CRC
Tang Nano / spi_image_top.v → gray_bowl_detector.v
                      ↓ resposta com contagens e classificação
camera_capture.py — valida resposta e publica /run/bowl/result.json
                      ↓ leitura de frames válidos e recentes
bowl_notifier.py — confirmação temporal e tentativa de envio via Twilio
```

A câmera disponibiliza a imagem pela rede; é o Raspberry que a busca. O celular não transmite diretamente para a FPGA. O endereço base inicialmente informado, `http://192.168.1.110:8080`, é a interface web. O exemplo de configuração usa `/shot.jpg` para fotografia, mas o endereço efetivamente usado no teste não aparece no log.

O cliente Assembly envia 23 comandos: GET_INFO, BEGIN, 19 blocos de pixels, END e GET_RESULT. Os blocos transportam 18 × 1.024 + 768 pixels. A FPGA processa um bloco por vez e mantém contagens, sem armazenar a imagem completa. Assembly e Python verificam integridade e identidade da resposta antes de publicar um resultado válido.

O detector considera claro um pixel cujo valor seja **estritamente maior que o threshold**. Para um frame de 19.200 pixels:

| Número de pixels claros | Classificação |
|---|---|
| Maior que 9.600 | `empty` — vazio |
| Menor que 9.600 | `not_empty` — não vazio |
| Igual a 9.600 | `unknown` — empate |

O valor 9.600 é a metade do total de pixels, não o threshold de intensidade. O exemplo usa threshold 100, porém o log não registra a configuração efetiva de threshold ou crop. A decisão é uma heurística de luminosidade; não há reconhecimento semântico de ração.

## 3. Problemas encontrados e tratamento adotado

| Problema | O que foi feito | Por que / situação atual |
|---|---|---|
| Erro de síntese `PJ0003: Unable to create output directory` | Foram consultados os eventos do Windows Defender. Houve registro de bloqueio do `gw_ide.exe` pelo Acesso Controlado a Pastas no diretório do projeto. Foi orientada a liberação específica desse executável. | A causa identificada era bloqueio de escrita do ambiente Windows. Não foi necessário alterar o RTL para tratar esse erro. A mudança efetiva da permissão e o relatório final de síntese não foram fornecidos. |
| `scp: stat local ... No such file or directory` | O procedimento foi corrigido para executar `scp` no PowerShell do Windows, onde estavam os arquivos, com caminhos usando `/`. | O comando havia sido executado no Raspberry com caminhos do Windows. As barras invertidas eram interpretadas pelo shell Linux. |
| Necessidade de ativar manualmente Python/venv e manter terminais abertos | Foram criados script Bash de preparação e serviços systemd de captura e notificação. | Os processos passam a ser supervisionados e podem iniciar no boot, usando diretamente o Python do venv. Não é necessário executar `source .../activate` em cada sessão. |
| Inicialização antes de a câmera estar disponível | Foi acrescentada uma verificação HTTP + conversão de imagem em `ExecStartPre`; o serviço tenta novamente após falha. | Evita iniciar a captura sem conseguir obter um snapshot utilizável. O log mostra recuperação após tentativas malsucedidas. |
| Falta de configuração separada para câmera e WhatsApp | Foram adicionados exemplos `camera.env.example` e `whatsapp.env.example`, validação de campos e criação de arquivos locais com permissão restrita. | Configurações podem ser ajustadas sem editar o programa, e valores de credenciais não são impressos pela verificação. Arquivos existentes são preservados. |
| Dependências sem preparação automatizada | O script instala pacotes de sistema ausentes, cria `.venv`, instala os requisitos Python e executa `make`. | Torna a instalação repetível. A preparação ocorre ao executar o instalador; o boot usa o ambiente pronto, sem depender de uma instalação via Internet a cada reinício. |
| Possibilidade de reutilizar resultado de outro boot | O serviço de captura publica em `/run/bowl/result.json`. | O diretório é gerenciado em tempo de execução pelo systemd. O estado de notificação fica separado em `/var/lib/bowl-notifier/state.json` para preservar o episódio. |

### Falha de câmera: recuperação observada, causa não determinada

O erro `URLError` informa falha na abertura do recurso HTTP, mas o diagnóstico atual não mostra seu motivo interno. O log não permite distinguir endereço incorreto, servidor desligado, conexão recusada, timeout ou falta de rota. Também não informa qual intervenção foi feita no celular ou na rede.

Às 02:00:39 aparece `Camera OK: snapshot convertido para 19200 pixels GRAY8`, seguido de `Started bowl-capture.service`. Isso comprova que a disponibilidade foi restabelecida e a política de repetição permitiu prosseguir. Não comprova uma correção específica de rede, nem que o código de captura precisou ser alterado naquele momento.

A melhoria do diagnóstico para detalhar causas de `URLError` foi discutida, mas **não está implementada no fonte inspecionado**. Não deve ser contabilizada como correção entregue.

## 4. Arquivos implementados e justificativas

| Arquivo em `pb/assembly` | Responsabilidade e motivo |
|---|---|
| `start_bowl.sh` | Centraliza preparação, verificação e instalação dos serviços para `/home/pi/pb`. Requer Linux AArch64, verifica SPI e usa um lock para impedir preparações concorrentes. |
| `deploy/preflight.py` | Valida configurações sem executar seu conteúdo como shell e verifica a câmera usando a mesma função de aquisição/conversão do programa principal. Não envia mensagens. |
| `deploy/bowl-capture.service` | Executa como `pi`, com grupo suplementar `spi`, verifica a câmera antes de iniciar e supervisiona a captura com repetição após falha. |
| `deploy/bowl-notifier.service` | Inicia o notificador com `--send`, confirmação de três frames vazios, rearme com dois frames não vazios e idade máxima de dez segundos. |
| `deploy/requirements.txt` | Declara as dependências `twilio` e `python-dotenv`. Os intervalos de versões não constituem um lock completo de dependências transitivas. |
| `deploy/camera.env.example` | Separa URL, threshold, intervalo e crop dos fontes. |
| `deploy/whatsapp.env.example` | Documenta os campos Twilio necessários sem incluir credenciais reais. |
| `tests/test_preflight.py` | Acrescenta oito testes de configuração, bloqueio de placeholders, crop e tratamento de falha sem exposição de valores sensíveis. |
| `Makefile` | Inclui os testes de preflight no alvo `make test`, além dos seis testes anteriores. |
| `deploy/README.md` | Registra instalação, operação, diagnóstico e limitações. |

Também foram adicionadas regras ao `.gitignore` para configurações locais e venv em `pb`. Isso não remove arquivos sensíveis anteriormente rastreados pelo Git.

O script possui três modos:

```bash
bash /home/pi/pb/start_bowl.sh --prepare       # dependências, venv e compilação
bash /home/pi/pb/start_bowl.sh                # valida, habilita e solicita partida
bash /home/pi/pb/start_bowl.sh --check-camera # apenas verifica câmera/conversão
```

O modo sem argumentos habilita envio real de WhatsApp. Ao ligar o Raspberry, systemd inicia os serviços; o script é chamado pelo serviço de captura no modo `--check-camera`. O instalador completo não é executado em todo boot. O sistema chama a API externa Twilio; não foi criado um servidor HTTP local.

## 5. Evidência do ensaio com pote sem e com ração

Os horários abaixo são os exibidos pelo `journalctl`. O texto não inclui ano ou offset de fuso; a data do relatório segue o contexto de 22/09/2026.

| Horário | Evento |
|---|---|
| 02:00:29–02:00:30 | Nova tentativa, contador 858; verificação falha com `URLError`. |
| 02:00:35 | Nova tentativa, contador 859. |
| 02:00:39 | Snapshot convertido e serviço de captura iniciado. |
| 02:00:42–02:00:53 | Frames 1–5: todos válidos e classificados como `empty`. |
| 02:02:32–02:03:03 | Frames 42–53: todos válidos; predominância de `not_empty`. |

O contador elevado indica repetidas tentativas anteriores, não uma quantidade de frames processados. O trecho não cobre toda a duração da indisponibilidade. Entre os dois recortes há um `Ctrl+C` no acompanhamento dos logs. Isso interrompe `journalctl`, não o serviço: o segundo trecho mantém o PID 8332 e a mesma sessão. Os frames 6–41 não foram incluídos e não podem ser avaliados.

### Resultados por frame

| Frame | Horário | Estado | Pixels claros | Percentual claro | Captura até publicação (s) |
|---|---|---|---:|---:|---:|
| 1 | 02:00:42 | empty | 16.083 | 83,77% | 2,801 |
| 2 | 02:00:45 | empty | 16.075 | 83,72% | 2,698 |
| 3 | 02:00:47 | empty | 16.077 | 83,73% | 2,653 |
| 4 | 02:00:50 | empty | 16.086 | 83,78% | 2,630 |
| 5 | 02:00:53 | empty | 16.081 | 83,76% | 2,662 |
| 42 | 02:02:32 | not_empty | 4.035 | 21,02% | 2,629 |
| 43 | 02:02:35 | not_empty | 6.962 | 36,26% | 2,698 |
| 44 | 02:02:38 | empty | 10.525 | 54,82% | 2,864 |
| 45 | 02:02:41 | not_empty | 5.538 | 28,84% | 2,762 |
| 46 | 02:02:43 | not_empty | 7.779 | 40,52% | 2,769 |
| 47 | 02:02:46 | not_empty | 2.812 | 14,65% | 2,737 |
| 48 | 02:02:49 | not_empty | 4.971 | 25,89% | 2,832 |
| 49 | 02:02:52 | not_empty | 6.019 | 31,35% | 2,718 |
| 50 | 02:02:55 | not_empty | 6.564 | 34,19% | 3,003 |
| 51 | 02:02:58 | not_empty | 6.391 | 33,29% | 2,787 |
| 52 | 02:03:00 | not_empty | 6.437 | 33,53% | 2,690 |
| 53 | 02:03:03 | not_empty | 6.263 | 32,62% | 2,796 |

Percentual claro = `pixels_bright / pixels_total × 100`. Tempo = `(publish_monotonic_ns − capture_monotonic_ns) / 10⁹`. A precisão de milissegundos apresentada é apenas arredondamento dos campos registrados.

### Interpretação das medidas

- Todos os 17 registros passam pelo caminho de validação de resultado e seguem a regra de maioria implementada no RTL. Isso valida consistência do protocolo/resultado nessas amostras, não 100% de acurácia visual.
- Os cinco primeiros frames apresentam 16.075–16.086 claros, com média de 16.080,4 (aproximadamente 83,75%). O comportamento é estável nesse pequeno intervalo.
- No segundo trecho, 11 de 12 frames são `not_empty`. O frame 44 é `empty` porque 10.525 claros superam o limite de 9.600; portanto, sua saída é coerente com a regra do detector.
- Se o pote já estava com ração e imóvel no frame 44, esse resultado é um possível falso positivo visual. Sem imagem ou marcação temporal da manipulação, não é possível confirmar isso ou atribuir a causa a luz, movimento ou enquadramento. Esses fatores são hipóteses para o próximo ensaio.
- A duração média de captura até publicação é **2,749 s**, com mínimo de **2,629 s** e máximo de **3,003 s**. Inclui aquisição, conversão, execução Assembly/SPI e validação até o timestamp de publicação; não é tempo exclusivo da FPGA nem inclui entrega de WhatsApp ou a conclusão do fsync do JSON.
- O intervalo nominal de dois segundos no exemplo não obriga ciclos a terminar em dois segundos. O código dorme apenas o tempo restante: se o trabalho demora mais, inicia o próximo ciclo sem essa pausa. As durações observadas são compatíveis com esse comportamento.

## 6. WhatsApp: configuração presente, entrega não demonstrada

O serviço versionado usa `--confirm 3 --rearm 2 --max-age 10 --send`. Pela política do código, uma ocorrência isolada de vazio, como o frame 44 entre frames não vazios, não completa as três confirmações necessárias. Os cinco primeiros frames poderiam completar a confirmação, desde que o notificador estivesse ativo, observasse esses resultados recentes e não houvesse um episódio já persistido.

Apesar de o comando consultar as duas unidades, o trecho anexado não mostra mensagens de `bowl-notifier`, ações `notify`/`rearm`, SID da Twilio ou estado de entrega. A ausência dessas linhas no recorte não prova falha nem sucesso do notificador. O estado anterior do episódio também não foi fornecido.

Para completar a evidência, coletar:

```bash
systemctl status bowl-notifier --no-pager
journalctl -u bowl-notifier -b --no-pager
cat /var/lib/bowl-notifier/state.json
```

`accepted` com SID significa aceitação pela API, não entrega confirmada. `pending` ou `unknown` exige investigação: o programa não repete cegamente uma tentativa que pode ter sido aceita. Confirmar entrega no console Twilio e no aparelho destinatário. Não apagar o arquivo de estado como rotina para forçar novos alertas.

## 7. Verificações anteriores e pendências preservadas

As auditorias anteriores registram seis testes de pipeline aprovados, compilação/execução AArch64 em QEMU, 31 respostas verificadas na suíte RTL (também a 100 kHz) e replay completo de 23 comandos/19.200 pixels. A etapa de automação acrescentou oito testes de preflight, totalizando 14 testes Python aprovados, além de validação estática de Bash e arquivos systemd. Esses resultados são históricos da sessão; não foram apresentados como novas execuções no Raspberry neste ensaio.

As auditorias inicialmente não tinham evidência física. O log agora complementa essa lacuna no fluxo nominal de captura e classificação, sem substituir ensaios de falhas elétricas, temporização ou boot a frio.

Os seguintes achados **continuam presentes nos fontes locais inspecionados** e não devem ser descritos como corrigidos:

1. `spi_diag.py` ainda emite magic `57 42`, divergente de `42 57` usado pelo Assembly e pelo RTL. O cliente principal não depende desse diagnóstico.
2. `tests/test_assembly_client.py` ainda procura `verilog_tp4` ao salvar o replay. O replay aprovado anteriormente foi preparado à parte; não houve correção desse caminho no gerador.
3. O erro de câmera continua resumido à classe da exceção. Falta distinguir causas de conexão sem expor informações sensíveis.
4. O log não documenta rotação/remoção histórica do código de recuperação 2FA apontado na auditoria. As novas regras de ignore não comprovam resolução desse achado.
5. Não há evidência de calibração sistemática, relatório de timing da implementação ou medição física de SPI. A disponibilização dos serviços também não comprova, por si só, que o celular e a FPGA reiniciam autonomamente.

## 8. Próximos critérios de aceitação

| Ensaio | Evidência esperada | Motivo |
|---|---|---|
| Repetir vazio → com ração → vazio, com horários anotados e câmera fixa | Frames/imagens associados à condição física e ações do notificador | Distinguir erro visual de transição durante manipulação. |
| Calibrar ROI e threshold, registrando os valores usados | Classificação consistente com diferentes níveis de ração e iluminação | Reduzir influência do fundo, reflexos e exposição. |
| Validar WhatsApp | SID, estado de entrega e recebimento no destinatário | Concluir o caminho de notificação, além da classificação. |
| Desligar e religar Raspberry, celular e Tang | Serviços ativos, snapshot acessível, bitstream carregado e novos resultados válidos | Comprovar autonomia após falta de energia. |
| Interromper câmera/rede e restaurar | Resultados inválidos ou ausência de novos dados durante a falha; recuperação sem alerta baseado em dado antigo | Validar tratamento de indisponibilidade e idade do resultado. |

Para investigar o classificador, registrar a imagem correspondente e os parâmetros efetivos de cada ensaio é mais informativo do que alterar imediatamente o threshold. O frame 44 merece reprodução controlada antes de se concluir que existe defeito no algoritmo ou no transporte SPI.

## 9. Referências e rastreabilidade

- [Evidência original do teste](evidencias/teste_fim_a_fim_2026-09-22.txt).
- [Auditoria Assembly](AUDITORIA_Assembly.md) e [auditoria Verilog](AUDITORIA_Verilog.md).
- [Procedimento de instalação](../assembly/deploy/README.md) e [script Bash](../assembly/start_bowl.sh).
- [Captura e validação](../assembly/camera_capture.py), [cliente Assembly](../assembly/spi_image_client.s) e [política de notificação](../assembly/bowl_notifier.py).
- [Serviço de captura](../assembly/deploy/bowl-capture.service), [serviço de WhatsApp](../assembly/deploy/bowl-notifier.service) e [verificação prévia](../assembly/deploy/preflight.py).
- [Detector de luminosidade](../verilog/assessment/src/spi_image/gray_bowl_detector.v) e [controle do protocolo SPI](../verilog/assessment/src/spi_image/spi_image_top.v).

Este relatório documenta alterações já realizadas e interpreta a evidência fornecida. Sua elaboração não modificou o código operacional, não acessou credenciais e não disparou mensagens.
