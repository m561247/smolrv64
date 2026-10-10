// The DMA masters' window onto DRAM: physical [0x8000_0000, 0x1_8000_0000), 4 GiB, is AXI byte
// address [0, 2^32) at the DDR4 controller. Included inside a module body.
//
// dram_ok:  the physical address lies in the window.
// dram_axi: its AXI address, PA - 0x8000_0000, which inside the window is PA[31:0] with bit 31
//           flipped. A board with 2 GiB of DDR4 ignores AXI bit 31 (the A16 row bit its parts do
//           not have), so its upper 2 GiB repeats the lower; its device tree describes 2 GiB.
function dram_ok(input [63:0] pa);
   dram_ok = pa[63:33] == 31'd0 && (pa[32] ^ pa[31]);
endfunction
function [31:0] dram_axi(input [63:0] pa);
   dram_axi = pa[31:0] ^ 32'h8000_0000;
endfunction
