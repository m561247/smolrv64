// The path history's step (smolrv64_predictor, smolrv64_core): a taken control transfer shifts the
// history one place and folds in its last halfword's address bits [GHL:1], the halfword its BTB
// entry is keyed by. A not-taken branch leaves the history alone, so every branch of one fetch
// pair is predicted with the same history, the one before the pair. Included inside a module body
// that defines GHL.
function [GHL-1:0] phist_step(input [GHL-1:0] g, input [PCW-1:0] last_hw);
   phist_step = {g[GHL-2:0], 1'b0} ^ last_hw[GHL:1];
endfunction
