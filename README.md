# Dog Bowl Detector

Sistema embarcado de visão computacional que detecta automaticamente quando o **pote de ração de um pet está vazio** e envia uma notificação por WhatsApp para o dono.

O projeto integra dois mundos de hardware:

- **FPGA (Gowin GW1NSR-4C / Tang Nano 4K)** — captura o vídeo de uma câmera OV2640, executa uma pipeline de visão computacional em hardware e decide, frame a frame, se o pote está vazio. O resultado é exposto em um pino GPIO (`alerta_vazio`).
- **Raspberry Pi Zero 2 W** — lê esse sinal via GPIO usando um programa em **Assembly ARM64**, publica o estado em um arquivo compartilhado e dispara a notificação de WhatsApp através de um serviço Python.

Este repositório contém a evolução do trabalho em vários TPs. **A versão mais atual e completa está na pasta [`tp4/`](tp4/)** e é a documentada aqui.

---

## Índice

- [Arquitetura](#arquitetura)
- [Estrutura do repositório](#estrutura-do-repositório)
- [Pré-requisitos de hardware](#pré-requisitos-de-hardware)
- [Parte 1 — FPGA (Verilog / Gowin)](#parte-1--fpga-verilog--gowin)
- [Parte 2 — Raspberry Pi (Assembly ARM64)](#parte-2--raspberry-pi-assembly-arm64)
- [Parte 3 — Notificação por WhatsApp](#parte-3--notificação-por-whatsapp)
- [Executando o sistema completo](#executando-o-sistema-completo)
- [Simulação e depuração](#simulação-e-depuração)

---

## Arquitetura

```
 ┌──────────────┐   vídeo    ┌──────────────────────────────────────────┐
 │ Câmera OV2640 │ ─────────▶ │  FPGA Gowin GW1NSR-4C (Tang Nano 4K)      │
 └──────────────┘   (DVP)    │                                            │
                             │  Frame Buffer (HyperRAM)                   │
                             │        │                                   │
                             │        ▼                                   │
                             │  Pipeline de Visão:                        │
                             │   RGB→Gray → ROI → Erosão 3x3 →            │
                             │   Detection Engine (histerese) → Overlay   │
                             │        │                    │              │
                             │        ▼                    ▼              │
                             │   alerta_vazio (GPIO)    HDMI (debug)      │
                             └────────┼───────────────────────────────────┘
                                      │ nível lógico (GPIO 22)
                                      ▼
                             ┌──────────────────────────────┐
                             │ Raspberry Pi Zero 2 W          │
                             │  gpio_poll.s (Assembly ARM64)  │
                             │   • lê GPIO 22 (sinal da FPGA) │
                             │   • acende LED no GPIO 21      │
                             │   • escreve /dev/shm/status_pote│
                             └───────────────┬────────────────┘
                                             │ arquivo de status
                                             ▼
                             ┌──────────────────────────────┐
                             │ whatsapp_api.py (Python)       │
                             │   • monitora o status          │
                             │   • envia WhatsApp via Twilio  │
                             └────────────────────────────────┘
```

O fluxo em uma frase: a **FPGA decide** se o pote está vazio, o **Assembly no Raspberry Pi lê essa decisão** via GPIO e o **Python notifica** o dono pelo WhatsApp.

---

## Estrutura do repositório

```
projeto-bloco-sistemas-digitais-embarcados/
├── README.md
└── tp4/                            ← versão mais atual (documentada aqui)
    ├── assembly_tp4/               ← código do Raspberry Pi
    │   ├── gpio_poll.s             ← polling do GPIO + escrita de status (programa principal)
    │   ├── gpio_map.s              ← demonstração comentada do mapa de registradores GPIO
    │   ├── command_processor.s     ← console de comandos (status/blink/log/reset/help)
    │   ├── whatsapp_api.py         ← envio de notificação via Twilio
    │   ├── start_detector.sh       ← script que sobe todo o pipeline no Pi
    │   ├── Makefile                ← build/disasm/debug do Assembly (as, ld, objdump, gdb)
    │   ├── .env.example            ← template das variáveis (Twilio + números)
    ├── verilog_tp4/
    │   └── assessment/             ← projeto Gowin (abrir assessment.gprj)
    │       └── src/
    │           ├── video_top.v            ← top-level (câmera → pipeline → HDMI/GPIO)
    │           ├── vision_pipeline/       ← rgb2gray, roi_window, erosion_3x3,
    │           │                             detection_engine, video_overlay
    │           ├── fsm/                    ← detector_top, fsm_detector, pixel_counter
    │           ├── ov2640/                 ← driver da câmera (SCCB/I2C)
    │           ├── hyperram_memory_interface/, video_frame_buffer/, dvi_tx/, syn_code/
    │           ├── dk_video.cst            ← constraints de pinos (pinout da placa)
    │           └── dk_video.sdc            ← constraints de timing
    └── docs_tp4/                   ← diagramas, waveforms, disassembly, relatório técnico
```

---

## Pré-requisitos de hardware

- Placa FPGA **Gowin GW1NSR-4C** (part `GW1NSR-LV4CQN48PC6/I5`) — o alvo usado é a Tang Nano 4K.
- Câmera **OV2640** conectada à FPGA (interface DVP + SCCB).
- Monitor **HDMI** (opcional, apenas para depuração visual com o overlay).
- **Raspberry Pi Zero 2 W** com Raspberry Pi OS (64-bit).
- Um jumper ligando o pino de saída `alerta_vazio` da FPGA ao **GPIO 22 (pino físico 15)** do Raspberry Pi, e um GND comum entre as placas.
- LED indicador opcional no **GPIO 21 (pino físico 40)** do Raspberry Pi.

> ⚠️ **Níveis de tensão:** os GPIOs do Raspberry Pi operam em 3,3 V. Garanta que a saída da FPGA esteja em 3,3 V (não 1,8 V/5 V) antes de conectar diretamente, para não danificar o Pi.

---

## Parte 1 — FPGA (Verilog / Gowin)

O código Verilog implementa a captura de vídeo e a pipeline de detecção. O módulo top-level é `video_top.v`, e o núcleo de decisão está em `vision_pipeline/`:

| Estágio | Módulo | Função |
|---------|--------|--------|
| 1 | `rgb2gray.v` | Converte RGB565 → tons de cinza (BT.601) |
| 2 | `roi_window.v` | Restringe a análise à região central onde o pote fica |
| 3 | `erosion_3x3.v` | Filtro morfológico que remove ruído/reflexos pontuais |
| 4 | `detection_engine.v` | Conta pixels claros e aplica histerese (dual threshold + confirmação multi-frame) |
| 5 | `video_overlay.v` | Desenha bounding box e status sobre a imagem enviada ao HDMI |

A saída `alerta_vazio` é levada ao pino `O_led[0]`, que também serve como sinal para o Raspberry Pi. Há ainda uma FSM alternativa mais simples em `fsm/` (`detector_top` + `fsm_detector` + `pixel_counter`) usada em simulação e nos TPs anteriores.

### Opção A — IDE Gowin (fluxo recomendado para gravar na placa)

1. Instale o **Gowin EDA** (Gowin IDE) e o driver USB da sua placa.
2. Abra o projeto: `File → Open Project` e selecione
   `tp4/verilog_tp4/assessment/assessment.gprj`.
3. Confirme o dispositivo: **GW1NSR-4C** (`GW1NSR-LV4CQN48PC6/I5`). O pinout já está definido em `src/dk_video.cst` e o timing em `src/dk_video.sdc`.
4. Rode **Synthesize** e depois **Place & Route**. O bitstream é gerado em
   `impl/pnr/assessment.fs`.
5. Abra o **Programmer**, conecte a placa e grave:
   - `SRAM Program` para teste volátil (perde ao desligar), ou
   - `embFlash / external Flash` para gravação persistente.
6. Com a câmera apontada para o pote, o pino `alerta_vazio` (`O_led[0]`) fica em nível alto quando o pote está vazio. Opcionalmente ligue o HDMI para ver o overlay.

### Opção B — Visual Studio Code (edição + simulação)

O VS Code não grava a FPGA, mas é ótimo para editar o Verilog e simular com ferramentas open-source:

1. Instale extensões úteis (ex.: *Verilog-HDL/SystemVerilog* para syntax highlight e linting).
2. Instale o **Icarus Verilog** (`iverilog`/`vvp`) e o **GTKWave**.
3. Compile e simule um testbench, por exemplo a FSM do detector:
   ```bash
   cd tp4/verilog_tp4/assessment/src/fsm
   iverilog -o sim_fsm.vvp tb_fsm_detector.v detector_top.v fsm_detector.v pixel_counter.v
   vvp sim_fsm.vvp
   gtkwave onda_fsm_detector.vcd
   ```
4. Para a gravação na placa, volte à Opção A (Gowin IDE) — é o passo obrigatório para colocar o bitstream na FPGA.

---

## Parte 2 — Raspberry Pi (Assembly ARM64)

O programa principal é `gpio_poll.s`. Ele acessa os registradores GPIO diretamente via `/dev/gpiomem` + `mmap`, faz polling do **GPIO 22** (sinal vindo da FPGA), acende o LED no **GPIO 21** e grava o estado em `/dev/shm/status_pote` (`0` = cheio, `1` = vazio). O mapeamento completo dos registradores está documentado em `gpio_map.s`.

### Toolchain

Você pode compilar de duas formas:

**Nativamente no Raspberry Pi** (recomendado):
```bash
sudo apt update
sudo apt install binutils gcc make gdb   # as, ld, objdump, gdb
```

**Por cross-compilação** (em um PC x86 com Linux/WSL):
```bash
sudo apt install binutils-aarch64-linux-gnu gdb-multiarch qemu-user
```

### Build

O `Makefile` cuida da montagem e linkagem estática de todos os `.s`:

```bash
cd tp4/assembly_tp4

# Compilação nativa (no próprio Raspberry Pi):
make

# Cross-compilação (a partir de x86/WSL):
make PREFIX=aarch64-linux-gnu
```

Os binários ficam em `build/bin/` (`gpio_poll`, `gpio_map`, `command_processor`).

Outros targets úteis:
```bash
make disasm      # gera disassembly comentado em disasm/*.txt (objdump -d -S)
make symbols BIN=gpio_poll   # tabela de símbolos
make info        # mostra a configuração do toolchain
make clean       # remove artefatos
```

### Console de comandos (opcional)

`command_processor.s` gera um binário interativo de demonstração (comandos `status`, `threshold`, `blink`, `log`, `reset`, `help`). Ele exercita loops, estruturas if/else e jump tables em Assembly:
```bash
./build/bin/command_processor
```

---

## Parte 3 — Notificação por WhatsApp

`whatsapp_api.py` monitora o arquivo `/dev/shm/status_pote` e, na transição de **cheio → vazio**, envia uma mensagem de WhatsApp usando a API da **Twilio**. Ele evita spam disparando apenas na mudança de estado.

Nada é hardcoded no código: as credenciais **e os números de WhatsApp** são lidos do arquivo `.env`. Se alguma variável obrigatória estiver faltando, o programa avisa e não inicia.

### Passo 1 — Criar uma conta na Twilio e obter as credenciais

O envio de WhatsApp depende de uma conta própria na Twilio. As secrets **não são versionadas** — cada pessoa precisa gerar as suas:

1. Crie uma conta gratuita em [twilio.com](https://www.twilio.com/try-twilio).
2. No [Console da Twilio](https://www.twilio.com/console), copie o seu **`TWILIO_ACCOUNT_SID`** e o **`TWILIO_AUTH_TOKEN`**.
3. Ative o **WhatsApp Sandbox** (menu *Messaging → Try it out → Send a WhatsApp message*). Anote o número de origem do sandbox (normalmente `+14155238886`) e siga as instruções para vincular o seu próprio número (enviar o código `join ...` para o sandbox).

### Passo 2 — Configurar o ambiente e o `.env`

1. Crie um ambiente virtual e instale as dependências (no Raspberry Pi):
   ```bash
   cd tp4/assembly_tp4
   python3 -m venv venv
   source venv/bin/activate
   pip install twilio python-dotenv
   ```
2. Copie o template `.env.example` para `.env` e preencha com **os seus** valores:
   ```bash
   cp .env.example .env
   ```
   ```env
   TWILIO_ACCOUNT_SID=seu_account_sid
   TWILIO_AUTH_TOKEN=seu_auth_token
   WHATSAPP_NUMBER_FROM=+14155238886     # número/sandbox da Twilio (origem)
   WHATSAPP_NUMBER_TO=+55XXXXXXXXXXX      # SEU WhatsApp (destino do alerta)
   ```
   Os números devem estar no formato internacional **E.164** (ex.: `+5521982974271`). O número de destino (`WHATSAPP_NUMBER_TO`) é para **onde a notificação será enviada** — informe o seu próprio WhatsApp.

> 🔒 **Segurança:** nunca faça commit do `.env` nem de tokens/recovery codes — o `.gitignore` já bloqueia `.env` e `twilio_2FA_recovery_code.*`, versionando apenas o template `.env.example`. Se alguma credencial já foi exposta em algum commit, revogue e gere um novo token no Console da Twilio.

---

## Executando o sistema completo

Com a FPGA já gravada e conectada ao Raspberry Pi, no Pi:

```bash
cd tp4/assembly_tp4
make                       # compila o Assembly (uma vez)
chmod +x start_detector.sh
./start_detector.sh
```

O script `start_detector.sh`:
1. Encerra execuções antigas de `gpio_poll` e `whatsapp_api.py`.
2. Sobe o `gpio_poll` (Assembly) em segundo plano — precisa de `sudo` para acessar o GPIO.
3. Aguarda a criação de `/dev/shm/status_pote`.
4. Ativa o `venv` e inicia o monitor Python do WhatsApp.

A partir daí: câmera vê o pote vazio → FPGA levanta `alerta_vazio` → Assembly grava `1` no status → Python envia o WhatsApp.

---

## Simulação e depuração

- **Waveforms da FPGA:** arquivos `.vcd` já incluídos em `src/` e `src/fsm/` podem ser abertos no GTKWave. Testbenches: `tb_detector.v`, `tb_testpattern.v`, `tb_fsm_detector.v`, `tb_vision_pipeline.v`.
- **Depuração do Assembly com GDB + QEMU** (útil em x86/WSL, sem hardware):
  ```bash
  make debug BIN=command_processor        # inicia QEMU com gdbserver na porta 1234
  # em outro terminal:
  make gdbconnect BIN=command_processor   # conecta o GDB e abre layout asm
  ```
- **Execução via QEMU** (rodar um binário ARM64 em x86):
  ```bash
  make run BIN=command_processor
  ```
- Documentação visual (diagramas, disassembly, tabela de símbolos, arquitetura) está em `tp4/docs_tp4/`, e o relatório técnico completo em
  `tp4/docs_tp4/Relatório Técnico - TP4 - Dog Bowl Detector.pdf`.
```
