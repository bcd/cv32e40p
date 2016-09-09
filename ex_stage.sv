// Copyright 2015 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the “License”); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Renzo Andri - andrire@student.ethz.ch                      //
//                                                                            //
// Additional contributions by:                                               //
//                 Igor Loi - igor.loi@unibo.it                               //
//                 Sven Stucki - svstucki@student.ethz.ch                     //
//                 Andreas Traber - atraber@iis.ee.ethz.ch                    //
//                                                                            //
// Design Name:    Execute stage                                             //
// Project Name:   RI5CY                                                      //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Execution stage: Hosts ALU and MAC unit                    //
//                 ALU: computes additions/subtractions/comparisons           //
//                 MAC:                                                       //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

`include "apu_defines.sv"

import riscv_defines::*;
import apu_params::*;

module riscv_ex_stage
(
  input  logic        clk,
  input  logic        rst_n,

  // ALU signals from ID stage
  input  logic [ALU_OP_WIDTH-1:0] alu_operator_i,
  input  logic [31:0] alu_operand_a_i,
  input  logic [31:0] alu_operand_b_i,
  input  logic [31:0] alu_operand_c_i,
  input  logic        alu_en_i,
  input  logic [ 4:0] bmask_a_i,
  input  logic [ 4:0] bmask_b_i,
  input  logic [ 1:0] imm_vec_ext_i,
  input  logic [ 1:0] alu_vec_mode_i,

  // Multiplier signals
  input  logic [ 2:0] mult_operator_i,
  input  logic [31:0] mult_operand_a_i,
  input  logic [31:0] mult_operand_b_i,
  input  logic [31:0] mult_operand_c_i,
  input  logic        mult_en_i,
  input  logic        mult_sel_subword_i,
  input  logic [ 1:0] mult_signed_mode_i,
  input  logic [ 4:0] mult_imm_i,

  input  logic [31:0] mult_dot_op_a_i,
  input  logic [31:0] mult_dot_op_b_i,
  input  logic [31:0] mult_dot_op_c_i,
  input  logic [ 1:0] mult_dot_signed_i,

  output logic        mult_multicycle_o,

`ifdef APU
  input  logic                       apu_en_i,
  input  logic [WAPUTYPE-1:0]        apu_type_i,
  input  logic [WOP_CPU-1:0]         apu_op_i,
  input  logic [NARGS_CPU-1:0][31:0] apu_operands_i,
  input  logic [NDSFLAGS_CPU-1:0]    apu_flags_i,
  input  logic [4:0]                 apu_waddr_i,

  input  logic [2:0][4:0]            apu_read_regs_i,
  input  logic [2:0]                 apu_read_regs_valid_i,
  output logic                       apu_read_dep_o,
  input  logic [1:0][4:0]            apu_write_regs_i,
  input  logic [1:0]                 apu_write_regs_valid_i,
  output logic                       apu_write_dep_o,

  cpu_marx_if.cpu                    apu_master,
`endif

  input  logic        lsu_en_i,

  // input from ID stage
  input  logic        branch_in_ex_i,
  input  logic [4:0]  regfile_alu_waddr_i,
  input  logic        regfile_alu_we_i,

  // directly passed through to WB stage, not used in EX
  input  logic        regfile_we_i,
  input  logic [4:0]  regfile_waddr_i,

  // CSR access
  input  logic        csr_access_i,
  input  logic [31:0] csr_rdata_i,

  // Output of EX stage pipeline
  output logic [4:0]  regfile_waddr_wb_o,
  output logic        regfile_we_wb_o,

  // Forwarding ports : to ID stage
  output logic  [4:0] regfile_alu_waddr_fw_o,
  output logic        regfile_alu_we_fw_o,
  output logic [31:0] regfile_alu_wdata_fw_o,    // forward to RF and ID/EX pipe, ALU & MUL

  // To IF: Jump and branch target and decision
  output logic [31:0] jump_target_o,
  output logic        branch_decision_o,

  // Stall Control
  input  logic        lsu_ready_ex_i, // EX part of LSU is done

  output logic        ex_ready_o, // EX stage ready for new data
  output logic        ex_valid_o, // EX stage gets new data
  input  logic        wb_ready_i  // WB stage ready for new data
);


  logic [31:0] alu_result;
  logic [31:0] alu_csr_result;
  logic [31:0] mult_result;
  logic        alu_cmp_result;

  logic        wb_contention;

  logic                    apu_en;
  logic                    apu_valid;
  logic [31:0]             apu_result;
  logic [NUSFLAGS_CPU-1:0] apu_flags;
  logic [4:0]              apu_waddr;
  logic [WAPUTYPE-1:0]     apu_type;
  logic                    apu_stall;

  logic        alu_ready;
  logic        mult_ready;


  // EX stage result mux (ALU, MAC unit, CSR)
  //assign alu_csr_result         = csr_access_i ? csr_rdata_i : alu_result;
  //
  //assign regfile_alu_wdata_fw_o = mult_en_i ? mult_result : alu_csr_result;
  //
  //
  //assign regfile_alu_we_fw_o    = regfile_alu_we_i;
  //assign regfile_alu_waddr_fw_o = regfile_alu_waddr_i;
  //

  always_comb
  begin
    regfile_alu_wdata_fw_o = '0;
    regfile_alu_waddr_fw_o = '0;
    regfile_alu_we_fw_o    = '0;
    wb_contention          = 1'b0;

    if (apu_valid) begin
      regfile_alu_we_fw_o    = 1'b1;
      regfile_alu_waddr_fw_o = apu_waddr;
      regfile_alu_wdata_fw_o = apu_result;

      if(alu_en_i | mult_en_i | csr_access_i) begin
        wb_contention = 1'b1;
      end
    end else begin
      regfile_alu_we_fw_o      = regfile_alu_we_i & ~apu_en;
      regfile_alu_waddr_fw_o   = regfile_alu_waddr_i;
      if (alu_en_i)
        regfile_alu_wdata_fw_o = alu_result;
      if (mult_en_i)
        regfile_alu_wdata_fw_o = mult_result;
      if (csr_access_i)
        regfile_alu_wdata_fw_o = csr_rdata_i;
    end

  end

  // branch handling
  assign branch_decision_o = alu_cmp_result;
  assign jump_target_o     = alu_operand_c_i;


  ////////////////////////////
  //     _    _    _   _    //
  //    / \  | |  | | | |   //
  //   / _ \ | |  | | | |   //
  //  / ___ \| |__| |_| |   //
  // /_/   \_\_____\___/    //
  //                        //
  ////////////////////////////

  riscv_alu alu_i
  (
    .clk                 ( clk             ),
    .rst_n               ( rst_n           ),

    .operator_i          ( alu_operator_i  ),
    .operand_a_i         ( alu_operand_a_i ),
    .operand_b_i         ( alu_operand_b_i ),
    .operand_c_i         ( alu_operand_c_i ),

    .vector_mode_i       ( alu_vec_mode_i  ),
    .bmask_a_i           ( bmask_a_i       ),
    .bmask_b_i           ( bmask_b_i       ),
    .imm_vec_ext_i       ( imm_vec_ext_i   ),

    .result_o            ( alu_result      ),
    .comparison_result_o ( alu_cmp_result  ),

    .ready_o             ( alu_ready       ),
    .ex_ready_i          ( ex_ready_o      )
  );


  ////////////////////////////////////////////////////////////////
  //  __  __ _   _ _   _____ ___ ____  _     ___ _____ ____     //
  // |  \/  | | | | | |_   _|_ _|  _ \| |   |_ _| ____|  _ \    //
  // | |\/| | | | | |   | |  | || |_) | |    | ||  _| | |_) |   //
  // | |  | | |_| | |___| |  | ||  __/| |___ | || |___|  _ <    //
  // |_|  |_|\___/|_____|_| |___|_|   |_____|___|_____|_| \_\   //
  //                                                            //
  ////////////////////////////////////////////////////////////////

  `ifndef SHARED_DSP_MULT
  riscv_mult mult_i
  (
    .clk             ( clk                  ),
    .rst_n           ( rst_n                ),

    .enable_i        ( mult_en_i            ),
    .operator_i      ( mult_operator_i      ),

    .short_subword_i ( mult_sel_subword_i   ),
    .short_signed_i  ( mult_signed_mode_i   ),

    .op_a_i          ( mult_operand_a_i     ),
    .op_b_i          ( mult_operand_b_i     ),
    .op_c_i          ( mult_operand_c_i     ),
    .imm_i           ( mult_imm_i           ),

    .dot_op_a_i      ( mult_dot_op_a_i      ),
    .dot_op_b_i      ( mult_dot_op_b_i      ),
    .dot_op_c_i      ( mult_dot_op_c_i      ),
    .dot_signed_i    ( mult_dot_signed_i    ),

    .result_o        ( mult_result          ),

    .multicycle_o    ( mult_multicycle_o    ),
    .ready_o         ( mult_ready           ),
    .ex_ready_i      ( ex_ready_o           )
  );
  `else
  assign mult_result = 32'b0;
  assign mult_ready  = 1'b1;
  assign mult_multicycle_o = 1'b0;
  `endif

  ////////////////////////////////////////////////////
  //     _    ____  _   _   ____ ___ ____  ____     //
  //    / \  |  _ \| | | | |  _ \_ _/ ___||  _ \    //
  //   / _ \ | |_) | | | | | | | | |\___ \| |_) |   //
  //  / ___ \|  __/| |_| | | |_| | | ___) |  __/    //
  // /_/   \_\_|    \___/  |____/___|____/|_|       //
  //                                                //
  ////////////////////////////////////////////////////



`ifdef APU
  assign apu_en = apu_en_i;

  apu_disp_v2 apu_disp_i
  (
   .clk_i              ( clk                            ),
   .rst_ni             ( rst_n                          ),

   .enable_i           ( apu_en                         ),
   .apu_type_i         ( apu_type_i                     ),
   .apu_op_i           ( apu_op_i                       ),
   .apu_operands_i     ( apu_operands_i                 ),
   .apu_flags_i        ( apu_flags_i                    ),
   .apu_waddr_i        ( apu_waddr_i                    ),

   .valid_o            ( apu_valid                      ),
   .apu_result_o       ( apu_result                     ),
   .apu_flags_o        ( apu_flags                      ),
   .apu_waddr_o        ( apu_waddr                      ),
   .apu_type_o         ( /* NYI, not needed for DSP */  ),

   .stall_i            ( ~wb_ready_i                    ),
   .stall_o            ( apu_stall                      ),

   .read_regs_i        ( apu_read_regs_i                ),
   .read_regs_valid_i  ( apu_read_regs_valid_i          ),
   .read_dep_o         ( apu_read_dep_o                 ),
   .write_regs_i       ( apu_write_regs_i               ),
   .write_regs_valid_i ( apu_write_regs_valid_i         ),
   .write_dep_o        ( apu_write_dep_o                ),

   .marx               ( apu_master                     )
   );
`else
  assign apu_en     = 1'b0;
  assign apu_valid  = 1'b0;
  assign apu_result = 32'b0;
  assign apu_flags  = '0;
  assign apu_waddr  = 5'b0;
  assign apu_stall  = 1'b0;
`endif


  ///////////////////////////////////////
  // EX/WB Pipeline Register           //
  ///////////////////////////////////////
  always_ff @(posedge clk, negedge rst_n)
  begin : EX_WB_Pipeline_Register
    if (~rst_n)
    begin
      regfile_waddr_wb_o   <= '0;
      regfile_we_wb_o      <= 1'b0;
    end
    else
    begin
      if (ex_valid_o) // wb_ready_i is implied
      begin
        regfile_we_wb_o    <= regfile_we_i;
        if (regfile_we_i) begin
          regfile_waddr_wb_o <= regfile_waddr_i;
        end
      end else if (wb_ready_i) begin
        // we are ready for a new instruction, but there is none available,
        // so we just flush the current one out of the pipe
        regfile_we_wb_o    <= 1'b0;
      end
    end
  end

  // As valid always goes to the right and ready to the left, and we are able
  // to finish branches without going to the WB stage, ex_valid does not
  // depend on ex_ready.
  assign ex_ready_o = (~apu_stall & alu_ready & mult_ready & lsu_ready_ex_i 
                       & wb_ready_i & ~wb_contention) | branch_in_ex_i;
  assign ex_valid_o = (apu_valid | alu_en_i | mult_en_i | csr_access_i | lsu_en_i)
                       & (alu_ready & mult_ready & lsu_ready_ex_i & wb_ready_i);

endmodule
