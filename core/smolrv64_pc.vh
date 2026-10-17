// A PC is PCW bits: a two's-complement number whose sign extension is the 64-bit address. Every
// canonical Sv39 address (bits [63:38] equal) and every physical address below 2**(PCW-1) is
// held exactly, and arithmetic on it (pc + 2, pc + an immediate) is the 64-bit arithmetic
// whenever the sum is one of those. A 64-bit value that becomes a PC (a jalr target, a trap
// vector, an xRET's epc) is packed: its low PCW-1 bits, and a top bit that keeps a non-canonical
// address non-canonical (va_codec.vh's PACK40 at PCW = 40), so it faults the same; the address it
// unpacks to is one such address, not necessarily that one, as the WARL epc and tval allow.
// Included inside a module body that has PCW.
function automatic [63:0] pc64(input [PCW-1:0] p);
   pc64 = {{(64-PCW){p[PCW-1]}}, p};
endfunction
function automatic [PCW-1:0] pcpack(input [63:0] v);
   pcpack = {v[PCW-2] ^ (v[63:PCW-1] != {(65-PCW){v[PCW-2]}}), v[PCW-2:0]};
endfunction
localparam [PCW-1:0] PC2 = 2, PC4 = 4, PC16 = 16;   // the steps a PC takes, at its width
