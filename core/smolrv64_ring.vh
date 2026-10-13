// THE OLDEST SET ENTRY OF A RING read from `base`, its oldest position: the lowest set index at or
// after base, or -- none there, so the ring wraps -- the lowest set index; base when none is set.
// Two find-firsts side by side and a choice between them: no rotation to base and no add back.
// Included inside a module; needs NENT and IDXB.
function [IDXB-1:0] ring_oldest(input [NENT-1:0] m, input [IDXB-1:0] base);
   reg [IDXB-1:0] a, b;  reg ah;  integer i;
   begin
      a = base;  b = base;  ah = 1'b0;
      for (i = NENT - 1; i >= 0; i = i - 1) begin
         if (m[i]) b = i[IDXB-1:0];
         if (m[i] && i[IDXB-1:0] >= base) begin a = i[IDXB-1:0]; ah = 1'b1; end
      end
      ring_oldest = ah ? a : b;
   end
endfunction
