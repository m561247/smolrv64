// The dispatch credits (`crd`): smolrv64_core computes them from flops, smolrv64_frontend's group
// rules read them. Lane k's scheduler has room (IW bits), the head-op register, then per slot
// position k (IW bits each) room for an FP op in the F stage, a load in the LQ and a store in the
// SQ with every slot before it holding one too, the ROB has room for slots 0..k (IW bits), then the
// pop, serialise, CSR and CBO gates, and no divide in flight. Needs IW.
localparam integer CR_IA = 0, CR_L = IW, CR_F = IW + 1, CR_LD = 2*IW + 1, CR_ST = 3*IW + 1,
                   CR_ROB1 = 4*IW + 1, CR_POP = 5*IW + 1, CR_SER = 5*IW + 2, CR_CSR = 5*IW + 3,
                   CR_CBO = 5*IW + 4, CR_DIV = 5*IW + 5, CRW = 5*IW + 6;
