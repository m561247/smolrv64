// The corrector's tag (smolrv64_predictor, smolrv64_wpick): a halfword's address folded to YTAGW
// bits. Included inside a module body that defines PCW, YBITS and YTAGW.
// The index consumes the halfword's bits [YB+3:1], so the tag carries them (rule B9).
function [YTAGW-1:0] ytagf(input [PCW-1:0] a);
   ytagf = a[YTAGW:1] ^ {{(2*YTAGW-YBITS){1'b0}}, a[YBITS:YTAGW+1]}
         ^ a[YBITS+YTAGW:YBITS+1] ^ a[YBITS+2*YTAGW:YBITS+YTAGW+1] ^ {{(YTAGW-1){1'b0}}, a[PCW-1]};
endfunction
