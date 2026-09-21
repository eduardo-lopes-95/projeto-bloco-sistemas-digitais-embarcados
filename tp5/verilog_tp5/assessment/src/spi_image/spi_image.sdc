// 27 MHz onboard system clock (period 37.037 ns).
create_clock -name I_clk -period 37.037 [get_ports {I_clk}]

// The SPI slave interface (SCLK/CS/MOSI) is driven by the Raspberry Pi and is
// asynchronous to I_clk. spi_slave_mode0.v oversamples and synchronizes these
// signals through 3-stage synchronizers before use, so the raw external inputs
// are treated as false paths into the 27 MHz domain to avoid meaningless
// setup/hold analysis on the clock crossing. Initial SPI rate is 100 kHz;
// with 27 MHz oversampling this is heavily overconstrained by design.
set_false_path -from [get_ports {I_spi_sclk}]
set_false_path -from [get_ports {I_spi_cs_n}]
set_false_path -from [get_ports {I_spi_mosi}]

// MISO is launched from I_clk and read by the Raspberry Pi on the SCLK edge it
// controls; the timing budget is dominated by the slow SPI period, not by I_clk.
set_false_path -to [get_ports {O_spi_miso}]

// Reset button and status LEDs are asynchronous / quasi-static.
set_false_path -from [get_ports {I_rst_n}]
set_false_path -to [get_ports {O_alert}]
set_false_path -to [get_ports {O_result_valid}]
