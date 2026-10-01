# Bowl Monitor — Detector de ração via FPGA

Sistema embarcado de visão computacional que detecta quando o **pote de ração de um pet está vazio** e envia uma notificação por WhatsApp para o dono.

A imagem é capturada por um celular rodando o app **IP Webcam**, processada no **Raspberry Pi** e classificada pela **Tang Nano 4K (FPGA Gowin)** via SPI. Quando o pote está vazio, o resultado chega ao Python, que notifica via **API Twilio/WhatsApp**.

---

## Fluxo do sistema

```
Celular (IP Webcam)
    │ snapshot HTTP
    ▼
Python + ffmpeg (Raspberry Pi)
    │ converte para GRAY8 160×120, grava frame.bowl
    ▼
Cliente Assembly AArch64 (spi_image_client)
    │ protocolo SPI (MOSI/MISO/SCLK/CS)
    ▼
FPGA Tang Nano 4K (RTL Verilog)
    │ conta pixels, decide por maioria
    ▼
Python (bowl_notifier / check_bowl.sh)
    │ API Twilio
    ▼
WhatsApp do dono
```

A FPGA não recebe JPEG, HTTP nem canais RGB. Ela recebe bytes de luminância (0–255) empacotados no protocolo SPI `BW` e decide: **maioria de pixels claros acima do threshold = pote vazio**.

---

## Estrutura do repositório

```
pb/
├── assembly/                      ← cliente Assembly AArch64
│   ├── spi_image_client.s         ← programa principal (sem libc, syscalls diretas)
│   ├── Makefile
│   └── tests/
│       └── test_assembly_client.py
│
├── integration/                   ← todo o Python
│   ├── camera_capture.py          ← captura HTTP, conversão ffmpeg, protocolo BOWL, SPI
│   ├── bowl_notifier.py           ← política de notificação (episódio, anti-spam, Twilio)
│   ├── check_bowl.sh              ← script único sob demanda (venv → câmera → FPGA → notify)
│   ├── deploy/
│   │   ├── preflight.py           ← validação de configuração e câmera
│   │   ├── requirements.txt
│   │   ├── camera.env.example     ← template: URL, THRESHOLD, INVERT_ARGS, CROP_ARGS
│   │   ├── whatsapp.env.example   ← template: credenciais Twilio
│   │   ├── bowl-capture.service   ← serviço systemd de captura contínua
│   │   └── bowl-notifier.service  ← serviço systemd de notificação contínua
│   ├── diagnostics/
│   │   ├── spi_diag.py            ← diagnóstico em camadas do SPI
│   │   ├── wire_check.py          ← teste de continuidade do cabeamento
│   │   └── make_test_frame.py     ← gera frame .bowl sintético sem câmera
│   └── tests/
│       ├── test_pipeline.py
│       └── test_preflight.py
│
├── verilog/
│   └── assessment/
│       ├── src/spi_image/
│       │   ├── spi_slave_mode0.v   ← recepção/transmissão serial, sincronizadores
│       │   ├── spi_image_top.v     ← enquadramento, CRC, FSM, BSRAM
│       │   └── gray_bowl_detector.v← contadores de pixels e decisão por maioria
│       └── sim/
│           ├── tb_spi_image.v      ← testbench geral (31 verificações)
│           ├── tb_bowl_empty.v     ← testbench focado em vazio (36 verificações)
│           ├── tb_bowl_silent.v    ← testbench adversarial / falhas silenciosas (27 verificações)
│           └── tb_assembly_replay.v← replay dos bytes gerados pelo Assembly
│
└── docs/
    ├── ARQUITETURA_TECNICA_ASSEMBLY_VERILOG.md  ← documentação técnica completa
    ├── RELATORIO_SESSAO_2026-09-28.md           ← diagnóstico e calibração
    ├── INTERPRETACAO_FORMA_DE_ONDA.md           ← guia GTKWave
    └── evidencias/                              ← fotos, capturas de tela, logs
```

---

## Pré-requisitos de hardware

| Componente | Detalhe |
|---|---|
| FPGA | Sipeed Tang Nano 4K (GW1NSR-LV4CQN48PC6/I5) |
| Raspberry Pi | Qualquer modelo com Linux AArch64 de 64 bits |
| Celular | App **IP Webcam** (Android) servindo `/shot.jpg` |
| Cabeamento SPI | MOSI (Pi 19 → Tang 42), MISO (Pi 21 → Tang 43), SCLK (Pi 23 → Tang 41), CS (Pi 24 → Tang 40), GND comum |

Os sinais SPI operam em 3,3 V (Banco 1 da Tang, LVCMOS33). Habilite o SPI no Raspberry com `sudo raspi-config` → Interface Options → SPI.

---

## Quickstart (modo sob demanda)

Esta é a forma mais rápida de testar o sistema sem instalar serviços.

### 1. Copiar os arquivos para o Raspberry

```powershell
# No PowerShell do Windows, na raiz do repositório:
ssh pi@SEU_IP "mkdir -p /home/pi/pb"
scp -r pb/assembly pb/integration pi@SEU_IP:/home/pi/pb/
```

### 2. Compilar o cliente Assembly (no Raspberry)

```bash
cd /home/pi/pb/assembly
make
ls -l build/bin/spi_image_client   # confirmar que compilou
```

### 3. Configurar os .env (no Raspberry)

```bash
cd /home/pi/pb/integration
cp deploy/camera.env.example camera.env
cp deploy/whatsapp.env.example whatsapp.env
chmod 600 camera.env whatsapp.env
nano camera.env      # ajuste CAMERA_URL, THRESHOLD e INVERT_ARGS
nano whatsapp.env    # preencha as credenciais Twilio
```

Valores calibrados para o cenário com fundo escuro (ração clara):

```bash
THRESHOLD=175
INVERT_ARGS=--invert
```

### 4. Rodar em modo dry-run (sem enviar WhatsApp)

```bash
bash /home/pi/pb/integration/check_bowl.sh --dry-run
```

Saída esperada:
```
[OK] venv e pacotes prontos
[OK] camera respondeu e converteu para GRAY8
[OK] FPGA respondeu: claros=.../19200
>>> POTE VAZIO <<<   (ou "Pote nao esta vazio.")
[dry-run] delegando ao bowl_notifier sem enviar...
```

### 5. Enviar a notificação de verdade

```bash
bash /home/pi/pb/integration/check_bowl.sh
```

Códigos de saída: `0` = vazio (notificação enviada), `10` = não vazio, `1` = falha.

---

## Modo serviço (execução contínua no boot)

Para que a captura rode automaticamente e envie notificações sem intervenção:

```bash
# Copiar os serviços systemd
sudo install -m 644 /home/pi/pb/integration/deploy/bowl-capture.service \
                    /home/pi/pb/integration/deploy/bowl-notifier.service \
                    /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now bowl-capture bowl-notifier

# Acompanhar logs
journalctl -u bowl-capture -u bowl-notifier -f
cat /run/bowl/result.json
cat /var/lib/bowl-notifier/state.json
```

O serviço de captura publica em `/run/bowl/result.json` a cada ~2 s. O notificador lê esse arquivo e envia o WhatsApp quando detecta 3 frames consecutivos com o pote vazio (`--confirm 3`), sem repetir enquanto o pote continuar vazio.

---

## Calibração óptica (threshold e inversão)

O detector decide por **maioria de pixels claros = vazio**. A calibração depende do seu cenário físico:

1. Fotografe o pote **cheio** e **vazio** com a mesma iluminação:

```bash
curl --fail --max-time 10 "SUA_CAMERA_URL" -o /tmp/cheio.jpg
curl --fail --max-time 10 "SUA_CAMERA_URL" -o /tmp/vazio.jpg
```

2. Meça a distribuição de luminância:

```bash
for estado in cheio vazio; do
  ffmpeg -y -loglevel error -i /tmp/$estado.jpg \
    -vf "scale=160:120,format=gray,negate" -f rawvideo /tmp/${estado}_inv.gray
  python3 -c "
d=open('/tmp/${estado}_inv.gray','rb').read()
print('$estado')
for t in range(140,200,10):
    c=sum(1 for x in d if x>t)
    print(f'  thr={t}: claros={c}/{len(d)} ({100*c//len(d)}%)')
"
done
```

3. Escolha o threshold onde cheio < 50% e vazio > 50%, com folga em ambos os lados. O valor `175` foi validado para ração clara sobre fundo escuro (cheio=33%, vazio=81%).

Se o seu cenário for inverso (fundo claro, ração escura), remova o `INVERT_ARGS` do `camera.env`.

---

## Simulação Verilog

Requisito: Icarus Verilog (`iverilog`/`vvp`) e GTKWave.

```bash
cd pb/verilog/assessment/sim
mkdir build

# Compilar e rodar todos os testbenches
S="../src/spi_image/gray_bowl_detector.v ../src/spi_image/spi_slave_mode0.v ../src/spi_image/spi_image_top.v"

iverilog -g2012 -s tb_spi_image    -o build/unit.vvp   tb_spi_image.v    $S && vvp build/unit.vvp
iverilog -g2012 -s tb_bowl_empty   -o build/empty.vvp  tb_bowl_empty.v   $S && vvp build/empty.vvp
iverilog -g2012 -s tb_bowl_silent  -o build/silent.vvp tb_bowl_silent.v  $S && vvp build/silent.vvp

# Abrir formas de onda no GTKWave
gtkwave build/tb_bowl_empty.vcd &
gtkwave build/tb_bowl_silent.vcd &
```

Resultados esperados:
- `tb_spi_image`: PASS: 31 respostas verificadas
- `tb_bowl_empty`: PASS: 36 respostas (vazio/não-vazio por margem de 1 pixel, single e multibloco)
- `tb_bowl_silent`: PASS: 27 respostas (6 testes adversariais de falhas silenciosas)

---

## Configuração Twilio

O envio usa o **Sandbox de WhatsApp** da Twilio para testes. Para operação fora da janela de 24 h, configure um template aprovado.

| Variável | Descrição |
|---|---|
| `TWILIO_ACCOUNT_SID` | SID da conta (Console Twilio) |
| `TWILIO_AUTH_TOKEN` | Token de autenticação |
| `TWILIO_WHATSAPP_FROM` | Número remetente no formato `whatsapp:+14155238886` |
| `TWILIO_WHATSAPP_TO` | Seu número no formato `whatsapp:+55DDDNUMERO` |
| `TWILIO_CONTENT_SID` | SID de template aprovado (opcional; sem ele usa texto livre, válido só na janela de 24 h) |

Antes de usar, o número destinatário precisa ter enviado `join <palavra>` para o número do Sandbox. Veja as instruções em [Twilio WhatsApp Sandbox](https://www.twilio.com/docs/whatsapp/sandbox).

> **Segurança:** nunca versione o `whatsapp.env` com credenciais reais. O `.gitignore` já bloqueia arquivos `.env`. Se uma credencial já foi exposta, revogue e gere um novo token no Console da Twilio.

---

## Diagnóstico

```bash
# Status dos serviços
systemctl status bowl-capture bowl-notifier --no-pager

# Logs em tempo real
journalctl -u bowl-capture -u bowl-notifier -f

# Último resultado classificado
cat /run/bowl/result.json

# Estado do episódio de notificação
cat /var/lib/bowl-notifier/state.json

# Testar só a câmera
python3 /home/pi/pb/integration/deploy/preflight.py camera /home/pi/pb/integration

# Diagnóstico do SPI (sem câmera necessária)
python3 /home/pi/pb/integration/diagnostics/spi_diag.py
```

Se o `state.json` mostrar `"status": "unknown"` com `"error": "TwilioRestException"`, o motivo está no código de erro da Twilio (visível em Monitor → Logs no Console). A causa mais comum é a janela de 24 h do Sandbox ter expirado — refaça o `join` no celular.

---

## Documentação técnica

| Documento | Conteúdo |
|---|---|
| [`docs/ARQUITETURA_TECNICA_ASSEMBLY_VERILOG.md`](docs/ARQUITETURA_TECNICA_ASSEMBLY_VERILOG.md) | Arquitetura completa: Assembly AArch64, protocolo SPI, RTL Verilog, timing, calibração e formas de onda |
| [`docs/INTERPRETACAO_FORMA_DE_ONDA.md`](docs/INTERPRETACAO_FORMA_DE_ONDA.md) | Guia de leitura dos sinais no GTKWave |
| [`docs/RELATORIO_SESSAO_2026-09-28.md`](docs/RELATORIO_SESSAO_2026-09-28.md) | Diagnóstico de campo, calibração óptica e reorganização do repositório |
