// THE KILL, AS A POSITION. While smolrv64_rob's kill is in force (kd_v), an op is dead when its
// ROB entry is younger than the walked-to branch: farther from kh, the head's position when the
// walk began, than the branch is (kb). Every structure that holds an op tests its own entry here,
// with two registers and a compare, instead of indexing the ROB's kill vector; smolrv64_rob holds
// this equal to its kd bit for every entry. Included inside a module; needs ROBB.
function kdead(input k_on, input [ROBB-1:0] k_head, input [ROBB-1:0] k_dist, input [ROBB-1:0] k_rob);
   reg [ROBB-1:0] k_d;
   begin
      k_d   = k_rob - k_head;
      kdead = k_on & (k_d > k_dist);
   end
endfunction
