// The pipeline's widths the design ships at, in ONE place: the core, the SoC top and the benches
// include it; the build (build.tcl), the runners and the bitstream cache read IW here.
// A -DSMOLRV64_IW=<n> (or _FW, _QD) overrides one for a run or a build.
`ifndef SMOLRV64_IW
 `define SMOLRV64_IW 4
`endif
`ifndef SMOLRV64_FW
 `define SMOLRV64_FW (2*`SMOLRV64_IW)  // fetch width: instructions into the decoupling queue per cycle (IW..8)
`endif
`ifndef SMOLRV64_QD
 `define SMOLRV64_QD 16                // the decoupling queue's depth (a power of two, at least 2*FW)
`endif
