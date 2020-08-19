`timescale 1ns / 1ns
// Interrupts are not handled in '816 mode so leave this undefined for now
//`ifdef REMAP_NATIVE_INTERRUPTS_D

// Depth of pipeline to delay switches to HS clock after an IO access. Need more cycles for
// faster clocks so ideally this should be linked with the divider setting. Over 16MHz needs
// 5 cycles but 13.8MHz seems ok with 4.
`define IO_ACCESS_DELAY_SZ             5

`define MAP_CC_DATA_SZ         7

`define SHADOW_MEM_IDX         6    
`define MAP_ROM_IDX            5
`define MAP_RAM_IDX            4
`define MAP_HSCLK_EN_IDX       2
`define CLK_CPUCLK_DIV_IDX_HI  1
`define CLK_CPUCLK_DIV_IDX_LO  0

`define BBC_PAGEREG_SZ         4    // only the bottom four ROM selection bits
`define GPIO_SZ                2

`define CPLD_REG_SEL_SZ        2
`define CPLD_REG_SEL_MAP_CC_IDX 1
`define CPLD_REG_SEL_BBC_PAGEREG_IDX 0

// Address of ROM selection reg in BBC memory map
`define BBC_PAGED_ROM_SEL 16'hFE30
// Assume that BBC ROM is at slot FF ( or at least ends with LSBs set...)
`define BASICROM_NUMBER 4'b1111

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
                      inout                rdy,
                      inout                nmib,
                      inout                irqb,
                      output               lat_en,
                      output               ram_web,
                      output               ram_ceb,
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
  reg                                  mos_sync_q;
  reg                                  himem_vram_wr_lat_q;  
  reg                                  himem_vram_wr_d;
  
  // This is the internal register controlling which features like high speed clocks etc are enabled
  reg [ `CPLD_REG_SEL_SZ-1:0]          cpld_reg_sel_q;
  // This will be a copy of the BBC ROM page register so we know which ROM is selected
  reg [`BBC_PAGEREG_SZ-1:0]            bbc_pagereg_q;
  reg [`MAP_CC_DATA_SZ-1:0]            map_data_q;
  reg                                  remapped_rom_access_r ;
  reg                                  remapped_ram_access_r ;
  reg [ `IO_ACCESS_DELAY_SZ-1:0]       io_access_pipe_q;
  wire                                 io_access_pipe_d;

  wire [ `CPLD_REG_SEL_SZ-1:0]         cpld_reg_sel_d;
  wire [7:0]                           cpu_hiaddr_lat_d;
  wire                                 rdy_w;
  wire                                 cpu_phi1_w;
  wire                                 cpu_phi2_w;
  wire                                 hs_selected_w;
  wire                                 ls_selected_w;
  wire                                 dummy_access_w;
  wire                                 sel_hs_w;
  wire                                 native_mode_int_w;
  wire                                 himem_w;
  wire                                 hisync_w;

  // Force keep intermediate nets to preserve strict delay chain for clocks
  (* KEEP="TRUE" *) wire ckdel_1_b, ckdel_3_b;
  (* KEEP="TRUE" *) wire ckdel_2, ckdel_4;

  INV    ckdel1   ( .I(bbc_phi0), .O(ckdel_1_b));
  INV    ckdel2   ( .I(ckdel_1_b),    .O(ckdel_2));
  INV    ckdel3   ( .I(ckdel_2),      .O(ckdel_3_b));
  INV    ckdel4   ( .I(ckdel_3_b),    .O(ckdel_4));

  clkctrl_phi2 U_0 (
                    .hsclk_in(hsclk),
                    .lsclk_in(ckdel_3_b),
                    .rst_b(resetb),
                    .hsclk_sel(sel_hs_w),
                    .cpuclk_div_sel(map_data_q[`CLK_CPUCLK_DIV_IDX_HI:`CLK_CPUCLK_DIV_IDX_LO]),
                    .hsclk_selected(hs_selected_w),
                    .lsclk_selected(ls_selected_w),
                    .clkout(cpu_phi1_w)
                    );

  assign cpu_phi2_w = !cpu_phi1_w ;
  assign cpu_phi2 =  cpu_phi2_w ;
  assign bbc_phi1 = ckdel_3_b;
  assign bbc_phi2 = ckdel_4;
  assign bbc_sync = cpu_vpa & cpu_vda;
  assign rdy = 1'bz;
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
  assign ram_web = cpu_rnw | !cpu_hiaddr_lat_q[6] ;  
  assign lat_en = !dummy_access_w;

  // All addresses starting 0b11 go to the on-board RAM and 0b10 to IO space, so check just bit 6
  assign ram_ceb = !( cpu_phi2_w && cpu_hiaddr_lat_q[6] );  

  // All addresses starting with 0b10 go to internal IO registers which update on the
  // rising edge of cpu_phi1 - use the cpu_data bus directly for the high address
  // bits since it's stable by the end of phi1
  assign cpld_reg_sel_d[`CPLD_REG_SEL_MAP_CC_IDX] = cpu_vda && ( cpu_data[7:6]== 2'b10) && ( cpu_adr[1:0] == 2'b11);
  assign cpld_reg_sel_d[`CPLD_REG_SEL_BBC_PAGEREG_IDX] = cpu_vda && (cpu_data[7]== 1'b0) && ( cpu_adr == `BBC_PAGED_ROM_SEL );

  // Force dummy read access when accessing himem explicitly but not for remapped RAM accesses which can still complete
  assign bbc_adr = ( dummy_access_w ) ? {8'h80} : cpu_adr[15:8] ;
  assign bbc_rnw = cpu_rnw | dummy_access_w ;

  assign bbc_data = ( !bbc_rnw & bbc_phi0 & bbc_phi2 & !hs_selected_w) ? cpu_data : { 8{1'bz}};
  assign cpu_data = cpu_data_r;


  always @ ( * ) begin
    if ( !map_data_q[`SHADOW_MEM_IDX] )
      // Need to mark VRAM writes for slow down unless using shadow memory
      himem_vram_wr_d = !cpu_data[7] & !cpu_adr[15] & (cpu_adr[14]|cpu_adr[13]) & !cpu_rnw  ;
    else
      // No need to mark any other remapped RAM for slow writes      
      himem_vram_wr_d = 1'b0;
  end
  
  // Check for accesses to IO space in case we need to delay switching back to HS clock
  assign io_access_pipe_d = !cpu_hiaddr_lat_q[7] & ( &(cpu_adr[15:10]) ) & cpu_vda;

  // Sel the high speed clock only
  // * on valid instruction fetches from himem, or
  // * on valid imm/data fetches from himem _if_ hs clock is already selected, or
  // * on invalid bus cycles if hs clock is already selected
  assign himem_w =  (cpu_vpa|cpu_vda) & (cpu_hiaddr_lat_q[7] & !himem_vram_wr_lat_q);
  assign hisync_w = (cpu_vpa&cpu_vda) & cpu_hiaddr_lat_q[7];

  assign sel_hs_w = map_data_q[`MAP_HSCLK_EN_IDX] & (( hisync_w & !io_access_pipe_q[0] ) |
                                                     ( himem_w & hs_selected_w) |
                                                     (!cpu_vpa & !cpu_vda & hs_selected_w)
                                                     ) ;
  assign dummy_access_w =  himem_w | !ls_selected_w ;

  // ROM remapping
  always @ ( * )
    if (!cpu_data[7] & map_data_q[`MAP_ROM_IDX] & cpu_adr[15] & (cpu_vpa|cpu_vda))
      // Remap MOS from C000-FBFF only (exclude IO space and vectors)
      if ( cpu_adr[14] & !(&(cpu_adr[13:10])))
        remapped_rom_access_r = 1;
      else if ( !cpu_adr[14] & (bbc_pagereg_q[`BBC_PAGEREG_SZ-1:0] == `BASICROM_NUMBER))
        remapped_rom_access_r = 1;
      else
        remapped_rom_access_r = 0;
    else
      remapped_rom_access_r = 0;

  always @ ( * ) begin
    if ( map_data_q[`SHADOW_MEM_IDX] ) begin
      // Always remap memory 0-8K when enabled, but only remap 8K-32K when not being accessed by MOS      
      if (!cpu_data[7] & map_data_q[`MAP_RAM_IDX] & !cpu_adr[15] & ( !(cpu_adr[14]|cpu_adr[13])  | !mos_sync_q ))
        remapped_ram_access_r = 1;        
      else
        remapped_ram_access_r = 0;
    end
    else begin
      if (!cpu_data[7] & map_data_q[`MAP_RAM_IDX] & !cpu_adr[15] )
        remapped_ram_access_r = 1;
      else
        remapped_ram_access_r = 0;
    end 
  end 
  
  
  assign cpu_hiaddr_lat_d[7:1] = cpu_data[7:1] | { 7{remapped_ram_access_r | remapped_rom_access_r | native_mode_int_w} };
  // Remapped accesses all go to the range FE0000 - FEFFFF, so don't set the bottom bit for these
  assign cpu_hiaddr_lat_d[0] = cpu_data[0] | native_mode_int_w;

  // drive cpu data if we're reading internal register or making a non dummy read from lomem
  always @ ( * )
    if ( cpu_phi2_w & cpu_rnw )
      begin
	if (cpu_hiaddr_lat_q[7])
	  if (cpld_reg_sel_q[`CPLD_REG_SEL_MAP_CC_IDX] ) begin
            // Not all bits are used so assign default first, then individual bits
	    cpu_data_r = 8'b0  ;
	    cpu_data_r[`MAP_HSCLK_EN_IDX]      = map_data_q[`MAP_HSCLK_EN_IDX] ;
	    cpu_data_r[`SHADOW_MEM_IDX]        = map_data_q[`SHADOW_MEM_IDX];
	    cpu_data_r[`MAP_ROM_IDX]           = map_data_q[`MAP_ROM_IDX];
	    cpu_data_r[`MAP_RAM_IDX]           = map_data_q[`MAP_RAM_IDX];
	    cpu_data_r[`CLK_CPUCLK_DIV_IDX_HI] = map_data_q[`CLK_CPUCLK_DIV_IDX_HI];
	    cpu_data_r[`CLK_CPUCLK_DIV_IDX_LO] = map_data_q[`CLK_CPUCLK_DIV_IDX_LO];
          end
          else //must be RAM access
            cpu_data_r = {8{1'bz}};
        else
          cpu_data_r = bbc_data;
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
        if (cpld_reg_sel_q[`CPLD_REG_SEL_MAP_CC_IDX] & !cpu_rnw ) begin
          // Not all bits are used so assign explicitly
	  map_data_q[`MAP_HSCLK_EN_IDX]       <= cpu_data[`MAP_HSCLK_EN_IDX] ;
	  map_data_q[`SHADOW_MEM_IDX]         <= cpu_data[`SHADOW_MEM_IDX];
	  map_data_q[`MAP_ROM_IDX]            <= cpu_data[`MAP_ROM_IDX];
	  map_data_q[`MAP_RAM_IDX]            <= cpu_data[`MAP_RAM_IDX];
	  map_data_q[`CLK_CPUCLK_DIV_IDX_HI]  <= cpu_data[`CLK_CPUCLK_DIV_IDX_HI];
	  map_data_q[`CLK_CPUCLK_DIV_IDX_LO]  <= cpu_data[`CLK_CPUCLK_DIV_IDX_LO];
        end        
        else if (cpld_reg_sel_q[`CPLD_REG_SEL_BBC_PAGEREG_IDX] & !cpu_rnw )
          bbc_pagereg_q <= cpu_data;
      end // else: !if( !resetb )


  // Flop all the internal register sel bits on falling edge of phi1
  always @ ( posedge cpu_phi2_w or negedge resetb )
    if ( !resetb )
        cpld_reg_sel_q <= {`CPLD_REG_SEL_SZ{1'b0}};
    else
        cpld_reg_sel_q <= cpld_reg_sel_d ;


  // Short pipeline to delay switching back to hs clock after an IO access to ensure any instruction
  // timed delays are respected.
  always @ ( negedge cpu_phi2_w or negedge resetb ) begin
    if ( !resetb )
      io_access_pipe_q <= `IO_ACCESS_DELAY_SZ'b0;
    else
      io_access_pipe_q <= ( io_access_pipe_q >> 1 )| {`IO_ACCESS_DELAY_SZ{ io_access_pipe_d }};
  end

  // Instruction was fetched from VDU routines in MOS if in the range FEC000 - FEDFFF (if remapped to himem)
  // or in range 00C000 - 00DFFF if ROM remapping disabled. ie can simplify deocoding here to say if in 
  // bank 8'bxxxxxxx0 (matches FE and 00) since we don't have instruction RAM anywhere else other than FF for native accesses 
  always @ ( negedge cpu_phi2_w )
    mos_sync_q <= (cpu_vpa & cpu_vda) ? ( !cpu_hiaddr_lat_q[0] & (cpu_adr[15:13]==3'b110)) : mos_sync_q;

  
  // Latches for the high address bits open during PHI1
  always @ ( * )
    if ( !cpu_phi2_w )
      begin
        cpu_hiaddr_lat_q <= cpu_hiaddr_lat_d;
        himem_vram_wr_lat_q <= himem_vram_wr_d;
      end

endmodule // level1b_m
