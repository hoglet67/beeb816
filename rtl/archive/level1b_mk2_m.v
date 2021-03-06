`timescale 1ns / 1ns
//
// PCB hacks
// 1. RAM_CEB and RAM_OEB separated
//    RAM_OEB connected now to GPIO0 (ie pin is still marked GPIO0 on the original mk2 PCB)
// 2. PCB Hack 2
//    RAM_ADR14,15 connected to GPIO1,2
//
// Interrupts are not handled in '816 mode so leave this undefined for now
//`ifdef REMAP_NATIVE_INTERRUPTS_D
// Depth of pipeline to delay switches to HS clock after an IO access. Need more cycles for
// faster clocks so ideally this should be linked with the divider setting. Over 16MHz needs
// 5 cycles but 13.8MHz seems ok with 4.
`define IO_ACCESS_DELAY_SZ     4
// Define this to get a clean deassertion/reassertion of RAM CEB but this limits some
// setup time from CEB low to data valid etc. Not an issue in a board with a faster
// SMD RAM so expect to set this in the final design, but omitting it can help with
// speed in the proto
`define ASSERT_RAMCEB_IN_PHI2  1
//
// Define this for the Acorn Electron instead of BBC Micro
// `define ELECTRON 1
//
// Define this for BBC B+/Master Shadow RAM control
//`define MASTER_SHADOW_CTRL 1
//
// Use data latches on CPU2BBC and/or BBC2CPU data transfers to improve hold times
`define USE_DATA_LATCHES_BBC2CPU 1
//`define USE_DATA_LATCHES_CPU2BBC 1
//
// Put latches on adr bits 13..8 (already have explicit latches on 14 and 15)
//`define USE_ADR_LATCHES_CPU2BBC 1
//
// Define this to use fast reads/slow writes to Shadow as with the VRAM to simplify decoding
//`define CACHED_SHADOW_RAM 1
//`define DIRECT_DRIVE_A13_A8
//`define NO_SELECT_FLOPS 1
//`define WRITE_PROTECT_REMAPPED_ROM 1
//
// Define this so that *TURBO enables both MOS and APPs ROMs
`define UNIFY_ROM_REMAP_BITS 1
//
// Define this for lazy decoding of bottom two bits in ROM paging, shadow RAM selection
//`define LAZY_REGISTER_DECODE 1
//
// Define this to delay the BBC_RNW low going edge by 2 inverter delays
`define DELAY_RNW_LOW  1
// Define this to bring out some signals to GPIO probe points
//`define ENABLE_PROBE_POINTS 1

// Define new memory MAP - merging MOS/RAM bank with interrupt vectors and relocating MOS to &8000 in that bank
`define NEW_MEMORY_MAP 1


`define MAP_CC_DATA_SZ         8
`define SHADOW_MEM_IDX         7
`define MAP_ROM_IDX            4
`ifdef UNIFY_ROM_REMAP_BITS
  `define MAP_MOS_IDX          `MAP_ROM_IDX
`else
  `define MAP_MOS_IDX            5
`endif
`define MAP_HSCLK_EN_IDX       2
`define CLK_CPUCLK_DIV_IDX_HI  1
`define CLK_CPUCLK_DIV_IDX_LO  0
`define BBC_PAGEREG_SZ         4    // only the bottom four ROM selection bits
`define GPIO_SZ                6

`ifdef MASTER_SHADOW_CTRL
`define CPLD_REG_SEL_SZ        3
`define CPLD_REG_SEL_BBC_SHADOW_IDX 2
`else
`define CPLD_REG_SEL_SZ        2
`endif
`define CPLD_REG_SEL_MAP_CC_IDX 1
`define CPLD_REG_SEL_BBC_PAGEREG_IDX 0

// Address of ROM selection reg in BBC memory map
`ifdef ELECTRON
  `define PAGED_ROM_SEL 16'hFE05
`else
  `define PAGED_ROM_SEL 16'hFE30
`endif

// BBC B+ uses bit 7 of &FE34 for shadow RAM select
`define SHADOW_RAM_SEL 16'hFE34

`ifdef LAZY_REGISTER_DECODE
  `define PAGED_ROM_SELECTION ( {cpu_adr[15:2], 2'b0} == `PAGED_ROM_SEL)
  `define SHADOW_RAM_SELECTION ( {cpu_adr[15:2], 2'b0} == `SHADOW_RAM_SEL)
`else
  // Default to full decode for the BBC B - seems unreliable otherwise although the Master seems ok with it
  `define PAGED_ROM_SELECTION (cpu_adr== `PAGED_ROM_SEL)
  `define SHADOW_RAM_SELECTION (cpu_adr== `SHADOW_RAM_SEL)
`endif

module level1b_mk2_m (
                      input [15:0]         cpu_adr,
                      input                resetb,
                      input                cpu_vpb,
                      input                cpu_e,
                      input                cpu_vda,
                      input                cpu_vpa,
                      input                bbc_phi0,
                      input                hsclk,
                      input                cpu_rnw,
                      inout [7:0]          cpu_data,
                      inout [7:0]          bbc_data,
                      inout [`GPIO_SZ-1:0] gpio,
                      input                rdy,
                      inout                nmib,
                      inout                irqb,
                      output               lat_en,
                      output               ram_web,
                      output               ram_ceb,
                      output               ram_oeb,
                      output               ram_adr18,
                      output               ram_adr17,
                      output               ram_adr16,
                      output               bbc_sync,
                      output [15:8]        bbc_adr,
                      output               bbc_rnw,
                      output               bbc_phi1,
                      output               bbc_phi2,
                      output               cpu_phi2
		  );

  reg [7:0]                            cpu_hiaddr_lat_q;
  reg [7:0]                            cpu_data_r;
  reg                                  mos_vdu_sync_q;
  reg                                  himem_vram_wr_lat_q;
`ifdef WRITE_PROTECT_REMAPPED_ROM
  reg                                  rom_wr_protect_lat_q;
`endif
`ifdef USE_DATA_LATCHES_BBC2CPU
  reg [7:0]                            bbc_data_lat_q;
`endif
`ifdef USE_DATA_LATCHES_CPU2BBC
  reg [7:0]                            cpu_data_lat_q;
`endif
// Only need to define latches for bits [13:8], since a15, a14 are handled separately and 7:0 are external to CPLD
`ifdef USE_ADR_LATCHES_CPU2BBC
  reg [5:0]                            cpu_adr_lat_q;
`endif
  // This is the internal register controlling which features like high speed clocks etc are enabled
`ifndef NO_SELECT_FLOPS
  reg [ `CPLD_REG_SEL_SZ-1:0]           cpld_reg_sel_q;
  wire [ `CPLD_REG_SEL_SZ-1:0]          cpld_reg_sel_d;
`endif
  // This will be a copy of the BBC ROM page register so we know which ROM is selected
  reg [`BBC_PAGEREG_SZ-1:0]            bbc_pagereg_q;
  reg [`MAP_CC_DATA_SZ-1:0]            map_data_q;
  reg                                  remapped_rom47_access_r ;
  reg                                  remapped_romCF_access_r ;
  reg                                  remapped_mos_access_r ;
  reg                                  remapped_ram_access_r ;
  reg                                  romCF_selected_q;
  reg                                  rom47_selected_q;
  reg                                  cpu_a15_lat_d;
  reg                                  cpu_a14_lat_d;
  reg                                  cpu_a15_lat_q;
  reg                                  cpu_a14_lat_q;
  reg [7:0]                            cpu_hiaddr_lat_d;
  reg [ `IO_ACCESS_DELAY_SZ-1:0]       io_access_pipe_q;
  wire                                 io_access_pipe_d;

  wire                                 himem_vram_wr_d;
  (* KEEP="TRUE" *) wire                                 cpu_phi1_w;
  wire                                 cpu_phi2_w;
  wire                                 hs_selected_w;
  wire                                 ls_selected_w;
  wire                                 dummy_access_w;
  wire                                 sel_hs_w;
  wire                                 native_mode_int_w;
  wire                                 himem_w;
  wire                                 hisync_w;
  wire [ `CPLD_REG_SEL_SZ-1:0]         cpld_reg_sel_w;

  // Force keep intermediate nets to preserve strict delay chain for clocks
  (* KEEP="TRUE" *) wire ckdel_1_b;
  (* KEEP="TRUE" *) wire ckdel_2;
  INV    ckdel1   ( .I(bbc_phi0), .O(ckdel_1_b));
  INV    ckdel2   ( .I(ckdel_1_b),    .O(ckdel_2));


  clkctrl_phi2 U_0 (
                    .hsclk_in(hsclk),
                    .lsclk_in(ckdel_1_b),
                    .rst_b(resetb),
                    .hsclk_sel(sel_hs_w),
                    .cpuclk_div_sel(map_data_q[`CLK_CPUCLK_DIV_IDX_HI:`CLK_CPUCLK_DIV_IDX_LO]),
                    .hsclk_selected(hs_selected_w),
                    .lsclk_selected(ls_selected_w),
                    .clkout(cpu_phi1_w)
                    );

  assign bbc_phi1 = ckdel_1_b;
  assign bbc_phi2 = ckdel_2;

  assign cpu_phi2_w = !cpu_phi1_w ;
  assign cpu_phi2 =  cpu_phi2_w ;

  assign bbc_sync = cpu_vpa & cpu_vda;
  assign irqb = 1'bz;
  assign nmib = 1'bz;

`ifdef REMAP_NATIVE_INTERRUPTS_D
  // Native mode interrupts will be redirected to himem
  assign native_mode_int_w = !cpu_vpb & !cpu_e ;
`else
  assign native_mode_int_w = 1'b0;
`endif

  // Drive the all RAM address pins, allowing for 512K RAM connection
  assign ram_adr16 = cpu_hiaddr_lat_q[0] ;
  assign ram_adr17 = cpu_hiaddr_lat_q[1] ;
  assign ram_adr18 = cpu_hiaddr_lat_q[2] ;
  // Override address bits A14/A15 when accessing remapped ROMs
  assign gpio[2] = cpu_a15_lat_q;
  assign gpio[1] = cpu_a14_lat_q;
  assign lat_en = !dummy_access_w;

`ifdef ENABLE_PROBE_POINTS
  // Bring some signals out to probe points
  assign gpio[3] = bbc_rnw;
  assign gpio[4] = bbc_phi2;
`endif

`ifdef ASSERT_RAMCEB_IN_PHI2
  // All addresses starting 0b11 go to the on-board RAM and 0b10 to IO space, so check just bit 6
  assign ram_ceb = !(cpu_hiaddr_lat_q[6] & (cpu_vda|cpu_vpa) & cpu_phi2_w) ;
  // PCB Hack 1 - gpio[0] = ram_oeb
  assign gpio[0] = cpu_phi1_w;
`ifdef WRITE_PROTECT_REMAPPED_ROM
  assign ram_web = cpu_rnw | rom_wr_protect_lat_q ;
`else
  assign ram_web = cpu_rnw ;
`endif
`else
  // All addresses starting 0b11 go to the on-board RAM and 0b10 to IO space, so check just bit 6
  assign ram_ceb = !(cpu_hiaddr_lat_q[6] & (cpu_vda|cpu_vpa)) ;
  // PCB Hack 1 - gpio[0] = ram_oeb
  assign gpio[0] = cpu_phi1_w ;
`ifdef WRITE_PROTECT_REMAPPED_ROM
  assign ram_web = cpu_rnw | cpu_phi1_w | rom_wr_protect_lat_q;
`else
  assign ram_web = cpu_rnw | cpu_phi1_w;
`endif
`endif

  // All addresses starting with 0b10 go to internal IO registers which update on the
  // rising edge of cpu_phi1 - use the cpu_data bus directly for the high address
  // bits since it's stable by the end of phi1
`ifdef NO_SELECT_FLOPS
  assign cpld_reg_sel_w[`CPLD_REG_SEL_MAP_CC_IDX] =  (cpu_hiaddr_lat_q[7:6]== 2'b10) && cpu_vda  && rdy ;
  assign cpld_reg_sel_w[`CPLD_REG_SEL_BBC_PAGEREG_IDX] = (cpu_hiaddr_lat_q[7]== 1'b0) && `PAGED_ROM_SELECTION && cpu_vda && rdy;
  `ifdef MASTER_SHADOW_CTRL
  assign cpld_reg_sel_w[`CPLD_REG_SEL_BBC_SHADOW_IDX] = (cpu_hiaddr_lat_q[7]== 1'b0) && `SHADOW_RAM_SELECTION && cpu_vda && rdy;
  `endif
`else
  assign cpld_reg_sel_w = cpld_reg_sel_q;
  assign cpld_reg_sel_d[`CPLD_REG_SEL_MAP_CC_IDX] =  ( cpu_data[7:6]== 2'b10);
  assign cpld_reg_sel_d[`CPLD_REG_SEL_BBC_PAGEREG_IDX] = (cpu_data[7]== 1'b0) && `PAGED_ROM_SELECTION ;
`ifdef MASTER_SHADOW_CTRL
  assign cpld_reg_sel_d[`CPLD_REG_SEL_BBC_SHADOW_IDX] = (cpu_data[7]== 1'b0) && `SHADOW_RAM_SELECTION ;
`endif
`endif

  // Force dummy read access when accessing himem explicitly but not for remapped RAM accesses which can still complete
`ifdef USE_ADR_LATCHES_CPU2BBC
  assign bbc_adr = { ( (dummy_access_w) ? 2'b10 : { cpu_a15_lat_q, cpu_a14_lat_q}), cpu_adr_lat_q };
`else
`ifdef DIRECT_DRIVE_A13_A8
  assign bbc_adr = { ((dummy_access_w) ? 2'b10 : cpu_adr[15:14]), cpu_adr[13:8]};
`else
  assign bbc_adr = { (dummy_access_w) ? 8'h80 : cpu_adr[15:8] };
`endif
`endif

`ifdef DELAY_RNW_LOW
  (* KEEP="TRUE" *) wire bbc_rnw_pre, bbc_rnw_b, bbc_rnw_del,bbc_rnw_b2, bbc_rnw_del2;
  assign bbc_rnw_pre = cpu_rnw | dummy_access_w ;
  INV    bbc_rnw_0( .I(bbc_rnw_pre), .O(bbc_rnw_b) );
  INV    bbc_rnw_1( .I(bbc_rnw_b), .O(bbc_rnw_del) );
  INV    bbc_rnw_2( .I(bbc_rnw_del), .O(bbc_rnw_b2) );
  INV    bbc_rnw_3( .I(bbc_rnw_b2), .O(bbc_rnw_del2) );
  assign bbc_rnw = bbc_rnw_del2 | bbc_rnw_pre;
`else
  assign bbc_rnw = cpu_rnw | dummy_access_w ;
`endif

`ifdef USE_DATA_LATCHES_CPU2BBC
  assign bbc_data = ( !bbc_rnw & bbc_phi2) ? cpu_data_lat_q : { 8{1'bz}};
`else
  assign bbc_data = ( !bbc_rnw & bbc_phi2) ? cpu_data : { 8{1'bz}};
`endif
  assign cpu_data = cpu_data_r;

  // Identify Video RAM so that in non shadow mode VRAM writes can be slowed down
  assign himem_vram_wr_d = !cpu_data[7] & !cpu_adr[15] & (cpu_adr[14] | (cpu_adr[13]&cpu_adr[12]))  ;

  // Check for write accesses to some of IO space (FE4x) in case we need to delay switching back to HS clock
  // so that min pulse widths to sound chip/reading IO are respected
  assign io_access_pipe_d = !cpu_hiaddr_lat_q[7] & (cpu_adr[15:4]==12'hFE4) & cpu_vda ;

  // Sel the high speed clock only
  // * on valid instruction fetches from himem, or
  // * on valid imm/data fetches from himem _if_ hs clock is already selected, or
  // * on invalid bus cycles if hs clock is already selected
  //
  // Option cached_shadow_ram can simplify the logic at the cost of making shadow and VRAM accesses both fast read/slow write
`ifdef CACHED_SHADOW_RAM
  assign himem_w =  (cpu_vpa|cpu_vda) & cpu_hiaddr_lat_q[7] & (!himem_vram_wr_lat_q | cpu_rnw );
`else
  assign himem_w =  (cpu_vpa|cpu_vda) & cpu_hiaddr_lat_q[7] & (!himem_vram_wr_lat_q | cpu_rnw | map_data_q[`SHADOW_MEM_IDX]);
`endif
  assign hisync_w = (cpu_vpa&cpu_vda) & cpu_hiaddr_lat_q[7];
  assign sel_hs_w = map_data_q[`MAP_HSCLK_EN_IDX] & (( hisync_w & !io_access_pipe_q[0] ) |
                                                     ( himem_w & hs_selected_w) |
                                                     (!cpu_vpa & !cpu_vda & hs_selected_w)
                                                     ) ;

  assign dummy_access_w =  himem_w | !ls_selected_w ;

  // ROM remapping
  always @ ( * ) begin
    // Split ROM and MOS identification to allow them to go to different banks later
    remapped_mos_access_r = 0;
    remapped_rom47_access_r = 0;
    remapped_romCF_access_r = 0;
    if (!cpu_data[7] & cpu_adr[15] & (cpu_vpa|cpu_vda)) begin
      // Remap MOS from C000-FBFF only (exclude IO space and vectors)
      if ( cpu_adr[14] & !(&(cpu_adr[13:10])) & map_data_q[`MAP_MOS_IDX] )
        remapped_mos_access_r = 1;
      else if (!cpu_adr[14] & map_data_q[`MAP_ROM_IDX] ) begin
        if ( bbc_pagereg_q[3:2] == 2'b11)
          remapped_romCF_access_r = 1;
        else if (bbc_pagereg_q[3:2] == 2'b01)
          remapped_rom47_access_r = 1;
      end
    end
  end

  always @ ( * ) begin
    if ( map_data_q[`SHADOW_MEM_IDX])
      // Always remap memory 0-12K in shadow mode, but only remap rest of RAM when not being accessed by MOS VDU routines
      // remap lomem = 0x0000 - 0x2FFF always              = !a15 & !a14 & !(a13 & a12)
      remapped_ram_access_r  = !cpu_data[7] & !cpu_adr[15] & ( (!cpu_adr[14] & !(cpu_adr[13] & cpu_adr[12])) | !mos_vdu_sync_q);
    else
      // Remap all of memory
      remapped_ram_access_r = (!cpu_data[7] & !cpu_adr[15]);
  end

  always @ ( * ) begin
    // Default assignments
    cpu_a15_lat_d = cpu_adr[15];
    cpu_a14_lat_d = cpu_adr[14];
    cpu_hiaddr_lat_d = cpu_data;

`ifdef NEW_MEMORY_MAP
    // Native mode interrupts go to bank 0xFF (with other native 816 code)
    if ( native_mode_int_w )
      cpu_hiaddr_lat_d = 8'hFF;
    // All remapped RAM/Mos accesses to 8'b1110x110
    else if ( remapped_ram_access_r )
      cpu_hiaddr_lat_d = 8'hFF;
    else if (remapped_mos_access_r) begin
      cpu_hiaddr_lat_d = 8'hFF;
      cpu_a14_lat_d = 1'b0;
    end    
    // All remapped ROM slots 4-7 accesses to 8'b1110x100
    else if (remapped_rom47_access_r) begin
      cpu_hiaddr_lat_d = 8'hFD;
      cpu_a15_lat_d = bbc_pagereg_q[1];
      cpu_a14_lat_d = bbc_pagereg_q[0];
    end
    // All remapped ROM slots C-F accesses to 8'b1110x101
    else if (remapped_romCF_access_r) begin
      cpu_hiaddr_lat_d = 8'hFE;
      cpu_a15_lat_d = bbc_pagereg_q[1];
      cpu_a14_lat_d = bbc_pagereg_q[0];
    end
`else    
    // Native mode interrupts go to bank 0xFF (with other native 816 code)
    if ( native_mode_int_w )
      cpu_hiaddr_lat_d = 8'hFF;
    // All remapped RAM/Mos accesses to 8'b1110x110
    else if ( remapped_ram_access_r | remapped_mos_access_r)
      cpu_hiaddr_lat_d = 8'hEE;
    // All remapped ROM slots 4-7 accesses to 8'b1110x100
    else if (remapped_rom47_access_r) begin
      cpu_hiaddr_lat_d = 8'hEC;
      cpu_a15_lat_d = bbc_pagereg_q[1];
      cpu_a14_lat_d = bbc_pagereg_q[0];
    end
    // All remapped ROM slots C-F accesses to 8'b1110x101
    else if (remapped_romCF_access_r) begin
      cpu_hiaddr_lat_d = 8'hED;
      cpu_a15_lat_d = bbc_pagereg_q[1];
      cpu_a14_lat_d = bbc_pagereg_q[0];
    end
`endif
  end

  // drive cpu data if we're reading internal register or making a non dummy read from lomem
  always @ ( * )
    if ( cpu_phi2_w & cpu_rnw )
      begin
	if (cpu_hiaddr_lat_q[7]) begin
	  if (cpld_reg_sel_w[`CPLD_REG_SEL_MAP_CC_IDX] ) begin
            // Not all bits are used so assign default first, then individual bits
	    cpu_data_r = 8'b0  ;
	    cpu_data_r[`MAP_HSCLK_EN_IDX]      = map_data_q[`MAP_HSCLK_EN_IDX] ;
	    cpu_data_r[`SHADOW_MEM_IDX]        = map_data_q[`SHADOW_MEM_IDX];
	    cpu_data_r[`MAP_MOS_IDX]           = map_data_q[`MAP_MOS_IDX];
	    cpu_data_r[`MAP_ROM_IDX]           = map_data_q[`MAP_ROM_IDX];
	    cpu_data_r[`CLK_CPUCLK_DIV_IDX_HI] = map_data_q[`CLK_CPUCLK_DIV_IDX_HI];
	    cpu_data_r[`CLK_CPUCLK_DIV_IDX_LO] = map_data_q[`CLK_CPUCLK_DIV_IDX_LO];
          end
          else //must be RAM access
            cpu_data_r = {8{1'bz}};
        end
        else
`ifdef USE_DATA_LATCHES_BBC2CPU
          cpu_data_r = bbc_data_lat_q;
`else
          cpu_data_r = bbc_data;
`endif
      end
    else
      cpu_data_r = {8{1'bz}};

  // -------------------------------------------------------------
  // All inferred flops and latches below this point
  // -------------------------------------------------------------
  // Internal registers update on the rising edge of cpu_phi1
  always @ ( negedge cpu_phi2_w or negedge resetb )
    if ( !resetb )
      begin
        map_data_q <= {`MAP_CC_DATA_SZ{1'b0}};
        bbc_pagereg_q <= {`BBC_PAGEREG_SZ{1'b0}};
      end
    else
      begin
        if (cpld_reg_sel_w[`CPLD_REG_SEL_MAP_CC_IDX] & !cpu_rnw) begin
          // Not all bits are used so assign explicitly
	  map_data_q[`MAP_HSCLK_EN_IDX]       <= cpu_data[`MAP_HSCLK_EN_IDX] ;
	  map_data_q[`SHADOW_MEM_IDX]         <= cpu_data[`SHADOW_MEM_IDX];
	  map_data_q[`MAP_MOS_IDX]            <= cpu_data[`MAP_MOS_IDX];
	  map_data_q[`MAP_ROM_IDX]            <= cpu_data[`MAP_ROM_IDX];
	  map_data_q[`CLK_CPUCLK_DIV_IDX_HI]  <= cpu_data[`CLK_CPUCLK_DIV_IDX_HI];
	  map_data_q[`CLK_CPUCLK_DIV_IDX_LO]  <= cpu_data[`CLK_CPUCLK_DIV_IDX_LO];
        end
        else if (cpld_reg_sel_w[`CPLD_REG_SEL_BBC_PAGEREG_IDX] & !cpu_rnw )
          bbc_pagereg_q <= cpu_data;
`ifdef MASTER_SHADOW_CTRL
        else if (cpld_reg_sel_w[`CPLD_REG_SEL_BBC_SHADOW_IDX] & !cpu_rnw )
          map_data_q[`SHADOW_MEM_IDX] <= cpu_data[`SHADOW_MEM_IDX];
`endif
      end // else: !if( !resetb )

`ifndef NO_SELECT_FLOPS
  // Flop all the internal register sel bits on falling edge of phi1
  always @ ( posedge cpu_phi2_w or negedge resetb )
    if ( !resetb )
        cpld_reg_sel_q <= {`CPLD_REG_SEL_SZ{1'b0}};
    else
        cpld_reg_sel_q <= (rdy & cpu_vda) ? cpld_reg_sel_d : {`CPLD_REG_SEL_SZ{1'b0}};
`endif


  // Short pipeline to delay switching back to hs clock after an IO access to ensure any instruction
  // timed delays are respected.
  always @ ( negedge cpu_phi2_w )
      io_access_pipe_q <= ( io_access_pipe_q >> 1 )| {`IO_ACCESS_DELAY_SZ{ io_access_pipe_d }};

  // Instruction was fetched from VDU routines in MOS if
  // - in the range EEC000 - EEDFFF (if remapped to himem)
  // - OR in range 00C000 - 00DFFF if ROM remapping disabled.
  //
  // Address bits
  // 23 22 21 20 19 18 17 16
  // 0  x  x  x  x  x  x  x   BBC Motherboard resources
  // 1  0  x  x  x  x  x  x   High IO Space
  // 1  1  0  x  x  0  0  0   5 banks of Native RAM for 816 (or more!)
  // 1  1  1  0  x  1  0  0   ROMS 4,5,6,7 remapping
  // 1  1  1  0  x  1  0  1   ROMS 12,13,14,15 remapping
  // 1  1  1  0  x  1  1  0   MOS + Shadow RAM/VRAM caching + low RAM (below 12K)
  // 1  1  1  1  1  1  1  1   816 vectors (not implemented)
  //
  // Decode VDU routines then as   xxx0_1110
  always @ ( negedge cpu_phi2_w )
    if ( cpu_vpa & cpu_vda)
      mos_vdu_sync_q <=   ((map_data_q[`MAP_MOS_IDX] && (cpu_hiaddr_lat_q[4:0]==5'h0E))||(!cpu_hiaddr_lat_q[7])) & (cpu_adr[15:13]==3'b110);

  // Latches for the high address bits open during PHI1
  always @ ( * )
    if ( rdy & !cpu_phi2_w )
      begin
        cpu_hiaddr_lat_q <= cpu_hiaddr_lat_d ;
        cpu_a15_lat_q <= cpu_a15_lat_d;
        cpu_a14_lat_q <= cpu_a14_lat_d;
        himem_vram_wr_lat_q <= himem_vram_wr_d;
`ifdef WRITE_PROTECT_REMAPPED_ROM
        rom_wr_protect_lat_q <= remapped_mos_access_r|remapped_romCF_access_r ;
`endif
      end

`ifdef USE_DATA_LATCHES_BBC2CPU
  // Latches for the BBC data open during PHI2 to be stable beyond cycle end
  always @ ( * )
    if ( !bbc_phi1 )
      bbc_data_lat_q <= bbc_data;
`endif

`ifdef USE_DATA_LATCHES_CPU2BBC
  always @ ( * )
    if ( cpu_phi2_w )
      cpu_data_lat_q <= cpu_data;
`endif

`ifdef USE_ADR_LATCHES_CPU2BBC
  always @ ( * )
    if ( cpu_phi1_w )
      cpu_adr_lat_q <= cpu_adr[13:8];
`endif


endmodule // level1b_m
