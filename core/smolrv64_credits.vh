// The dispatch credits (`crd`): smolrv64_core computes them from flops, smolrv64_frontend's group
// rules read them. Lane k's scheduler has room (IW bits), the head-op register, the F stage has
// room for an FP op in slot position k with every slot before it holding one too (IW bits), the
// LQ, the SQ, the ROB has room for slots 0..k (IW bits), then the pop, serialise, CSR and CBO
// gates, and no divide in flight. Needs IW.
localparam integer CR_IA = 0, CR_L = IW, CR_F = IW + 1, CR_LD = 2*IW + 1, CR_ST = 2*IW + 2,
                   CR_ROB1 = 2*IW + 3, CR_POP = 3*IW + 3, CR_SER = 3*IW + 4, CR_CSR = 3*IW + 5,
                   CR_CBO = 3*IW + 6, CR_DIV = 3*IW + 7, CRW = 3*IW + 8;
