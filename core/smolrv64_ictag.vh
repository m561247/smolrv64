// The I$ request tag's width, the one definition every module and bench carrying the tag uses
// (smolrv64_fring builds it: the pair's marks, its end, its skip and the stream generation, and
// asserts this matches).
`ifndef SMOLRV64_ICTAG_VH
`define SMOLRV64_ICTAG_VH
`define SMOLRV64_ICTAG_W 17
`endif
