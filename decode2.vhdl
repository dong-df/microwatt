library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.decode_types.all;
use work.common.all;
use work.helpers.all;
use work.insn_helpers.all;

entity decode2 is
    generic (
        EX1_BYPASS : boolean := true;
        HAS_FPU : boolean := true;
        -- Non-zero to enable log data collection
        LOG_LENGTH : natural := 0
        );
    port (
        clk   : in std_ulogic;
        rst   : in std_ulogic;

        complete_in : in instr_tag_t;
        busy_in   : in std_ulogic;
        stall_out : out std_ulogic;

        stopped_out : out std_ulogic;

        flush_in: in std_ulogic;

        d_in  : in Decode1ToDecode2Type;

        e_out : out Decode2ToExecute1Type;

        r_in  : in RegisterFileToDecode2Type;
        r_out : out Decode2ToRegisterFileType;

        c_in  : in CrFileToDecode2Type;
        c_out : out Decode2ToCrFileType;

        execute_bypass    : in bypass_data_t;
        execute_cr_bypass : in cr_bypass_data_t;
        execute2_bypass    : in bypass_data_t;
        execute2_cr_bypass : in cr_bypass_data_t;
        writeback_bypass  : in bypass_data_t;

        log_out : out std_ulogic_vector(9 downto 0)
	);
end entity decode2;

architecture behaviour of decode2 is
    type reg_type is record
        e : Decode2ToExecute1Type;
        repeat : repeat_t;
        busy : std_ulogic;
        sgl_pipe : std_ulogic;
        prev_sgl : std_ulogic;
        reg_a_valid : std_ulogic;
        reg_b_valid : std_ulogic;
        reg_c_valid : std_ulogic;
        reg_o_valid : std_ulogic;
        input_ov  : std_ulogic;
        output_ov : std_ulogic;
    end record;
    constant reg_type_init : reg_type :=
        (e => Decode2ToExecute1Init, repeat => NONE, others => '0');

    signal dc2, dc2in : reg_type;

    signal deferred : std_ulogic;

    type decode_input_reg_t is record
        reg_valid : std_ulogic;
        reg       : gspr_index_t;
        data      : std_ulogic_vector(63 downto 0);
    end record;
    constant decode_input_reg_init : decode_input_reg_t := ('0', (others => '0'), (others => '0'));

    type decode_output_reg_t is record
        reg_valid : std_ulogic;
        reg       : gspr_index_t;
    end record;
    constant decode_output_reg_init : decode_output_reg_t := ('0', (others => '0'));

    function decode_input_reg_a (t : input_reg_a_t; insn_in : std_ulogic_vector(31 downto 0);
                                 ispr : gspr_index_t;
                                 instr_addr : std_ulogic_vector(63 downto 0))
        return decode_input_reg_t is
    begin
        if t = RA or (t = RA_OR_ZERO and insn_ra(insn_in) /= "00000") then
            return ('1', gpr_to_gspr(insn_ra(insn_in)), (others => '0'));
        elsif t = SPR then
            -- ISPR must be either a valid fast SPR number or all 0 for a slow SPR.
            -- If it's all 0, we don't treat it as a dependency as slow SPRs
            -- operations are single issue.
            --
            assert is_fast_spr(ispr) =  '1' or ispr = "0000000"
                report "Decode A says SPR but ISPR is invalid:" &
                to_hstring(ispr) severity failure;
            return (is_fast_spr(ispr), ispr, (others => '0'));
        elsif t = CIA then
            return ('0', (others => '0'), instr_addr);
        elsif HAS_FPU and t = FRA then
            return ('1', fpr_to_gspr(insn_fra(insn_in)), (others => '0'));
        else
            return ('0', (others => '0'), (others => '0'));
        end if;
    end;

    function decode_input_reg_b (t : input_reg_b_t; insn_in : std_ulogic_vector(31 downto 0);
                                 ispr : gspr_index_t) return decode_input_reg_t is
        variable ret : decode_input_reg_t;
    begin
        case t is
            when RB =>
                ret := ('1', gpr_to_gspr(insn_rb(insn_in)), (others => '0'));
            when FRB =>
                if HAS_FPU then
                    ret := ('1', fpr_to_gspr(insn_frb(insn_in)), (others => '0'));
                else
                    ret := ('0', (others => '0'), (others => '0'));
                end if;
            when CONST_UI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(unsigned(insn_ui(insn_in)), 64)));
            when CONST_SI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_si(insn_in)), 64)));
            when CONST_SI_HI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_si(insn_in)) & x"0000", 64)));
            when CONST_UI_HI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(unsigned(insn_si(insn_in)) & x"0000", 64)));
            when CONST_LI =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_li(insn_in)) & "00", 64)));
            when CONST_BD =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_bd(insn_in)) & "00", 64)));
            when CONST_DS =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_ds(insn_in)) & "00", 64)));
            when CONST_DQ =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_dq(insn_in)) & "0000", 64)));
            when CONST_DXHI4 =>
                ret := ('0', (others => '0'), std_ulogic_vector(resize(signed(insn_dx(insn_in)) & x"0004", 64)));
            when CONST_M1 =>
                ret := ('0', (others => '0'), x"FFFFFFFFFFFFFFFF");
            when CONST_SH =>
                ret := ('0', (others => '0'), x"00000000000000" & "00" & insn_in(1) & insn_in(15 downto 11));
            when CONST_SH32 =>
                ret := ('0', (others => '0'), x"00000000000000" & "000" & insn_in(15 downto 11));
            when SPR =>
                -- ISPR must be either a valid fast SPR number or all 0 for a slow SPR.
                -- If it's all 0, we don't treat it as a dependency as slow SPRs
                -- operations are single issue.
                assert is_fast_spr(ispr) = '1' or ispr = "0000000"
                    report "Decode B says SPR but ISPR is invalid:" &
                    to_hstring(ispr) severity failure;
                ret := (is_fast_spr(ispr), ispr, (others => '0'));
            when NONE =>
                ret := ('0', (others => '0'), (others => '0'));
        end case;

        return ret;
    end;

    function decode_input_reg_c (t : input_reg_c_t; insn_in : std_ulogic_vector(31 downto 0))
        return decode_input_reg_t is
    begin
        case t is
            when RS =>
                return ('1', gpr_to_gspr(insn_rs(insn_in)), (others => '0'));
            when RCR =>
                return ('1', gpr_to_gspr(insn_rcreg(insn_in)), (others => '0'));
            when FRS =>
                if HAS_FPU then
                    return ('1', fpr_to_gspr(insn_frt(insn_in)), (others => '0'));
                else
                    return ('0', (others => '0'), (others => '0'));
                end if;
            when FRC =>
                if HAS_FPU then
                    return ('1', fpr_to_gspr(insn_frc(insn_in)), (others => '0'));
                else
                    return ('0', (others => '0'), (others => '0'));
                end if;
            when NONE =>
                return ('0', (others => '0'), (others => '0'));
        end case;
    end;

    function decode_output_reg (t : output_reg_a_t; insn_in : std_ulogic_vector(31 downto 0);
                                ispr : gspr_index_t) return decode_output_reg_t is
    begin
        case t is
            when RT =>
                return ('1', gpr_to_gspr(insn_rt(insn_in)));
            when RA =>
                return ('1', gpr_to_gspr(insn_ra(insn_in)));
            when FRT =>
                if HAS_FPU then
                    return ('1', fpr_to_gspr(insn_frt(insn_in)));
                else
                    return ('0', "0000000");
                end if;
            when SPR =>
                -- ISPR must be either a valid fast SPR number or all 0 for a slow SPR.
                -- If it's all 0, we don't treat it as a dependency as slow SPRs
                -- operations are single issue.
                assert is_fast_spr(ispr) = '1' or ispr = "0000000"
                    report "Decode B says SPR but ISPR is invalid:" &
                    to_hstring(ispr) severity failure;
                return (is_fast_spr(ispr), ispr);
            when NONE =>
                return ('0', "0000000");
        end case;
    end;

    function decode_rc (t : rc_t; insn_in : std_ulogic_vector(31 downto 0)) return std_ulogic is
    begin
        case t is
            when RC =>
                return insn_rc(insn_in);
            when ONE =>
                return '1';
            when NONE =>
                return '0';
        end case;
    end;

    -- control signals that are derived from insn_type
    type mux_select_array_t is array(insn_type_t) of std_ulogic_vector(2 downto 0);

    constant result_select : mux_select_array_t := (
        OP_AND      => "001",           -- logical_result
        OP_OR       => "001",
        OP_XOR      => "001",
        OP_PRTY     => "001",
        OP_CMPB     => "001",
        OP_EXTS     => "001",
        OP_BPERM    => "001",
        OP_BCD      => "001",
        OP_MTSPR    => "001",
        OP_RLC      => "010",           -- rotator_result
        OP_RLCL     => "010",
        OP_RLCR     => "010",
        OP_SHL      => "010",
        OP_SHR      => "010",
        OP_EXTSWSLI => "010",
        OP_MUL_L64  => "011",           -- muldiv_result
        OP_B        => "110",           -- next_nia
        OP_BC       => "110",
        OP_BCREG    => "110",
        OP_ADDG6S   => "111",           -- misc_result
        OP_ISEL     => "111",
        OP_DARN     => "111",
        OP_MFMSR    => "111",
        OP_MFCR     => "111",
        OP_SETB     => "111",
        others      => "000"            -- default to adder_result
        );

    constant subresult_select : mux_select_array_t := (
        OP_MUL_L64 => "000",            -- muldiv_result
        OP_MUL_H64 => "001",
        OP_MUL_H32 => "010",
        OP_DIV     => "011",
        OP_DIVE    => "011",
        OP_MOD     => "011",
        OP_ADDG6S  => "001",            -- misc_result
        OP_ISEL    => "010",
        OP_DARN    => "011",
        OP_MFMSR   => "100",
        OP_MFCR    => "101",
        OP_SETB    => "110",
        OP_CMP     => "000",            -- cr_result
        OP_CMPRB   => "001",
        OP_CMPEQB  => "010",
        OP_CROP    => "011",
        OP_MCRXRX  => "100",
        OP_MTCRF   => "101",
        others     => "000"
        );

    signal decoded_reg_a : decode_input_reg_t;
    signal decoded_reg_b : decode_input_reg_t;
    signal decoded_reg_c : decode_input_reg_t;
    signal decoded_reg_o : decode_output_reg_t;

    -- issue control signals
    signal control_valid_in : std_ulogic;
    signal control_valid_out : std_ulogic;
    signal control_serialize : std_logic;

    signal gpr_write_valid : std_ulogic;
    signal gpr_write : gspr_index_t;

    signal gpr_a_read_valid : std_ulogic;
    signal gpr_a_read       : gspr_index_t;
    signal gpr_a_bypass     : std_ulogic_vector(1 downto 0);

    signal gpr_b_read_valid : std_ulogic;
    signal gpr_b_read       : gspr_index_t;
    signal gpr_b_bypass     : std_ulogic_vector(1 downto 0);

    signal gpr_c_read_valid : std_ulogic;
    signal gpr_c_read       : gspr_index_t;
    signal gpr_c_bypass     : std_ulogic_vector(1 downto 0);

    signal cr_read_valid   : std_ulogic;
    signal cr_write_valid  : std_ulogic;
    signal cr_bypass       : std_ulogic_vector(1 downto 0);

    signal ov_read_valid   : std_ulogic;
    signal ov_write_valid  : std_ulogic;

    signal instr_tag       : instr_tag_t;

begin
    control_0: entity work.control
	generic map (
            EX1_BYPASS => EX1_BYPASS
            )
	port map (
            clk         => clk,
            rst         => rst,

            complete_in => complete_in,
            valid_in    => control_valid_in,
            deferred    => deferred,
            flush_in    => flush_in,
            serialize   => control_serialize,
            stop_mark_in => d_in.stop_mark,

            gpr_write_valid_in => gpr_write_valid,
            gpr_write_in       => gpr_write,

            gpr_a_read_valid_in  => gpr_a_read_valid,
            gpr_a_read_in        => gpr_a_read,

            gpr_b_read_valid_in  => gpr_b_read_valid,
            gpr_b_read_in        => gpr_b_read,

            gpr_c_read_valid_in  => gpr_c_read_valid,
            gpr_c_read_in        => gpr_c_read,

            execute_next_tag     => execute_bypass.tag,
            execute_next_cr_tag  => execute_cr_bypass.tag,
            execute2_next_tag    => execute2_bypass.tag,
            execute2_next_cr_tag => execute2_cr_bypass.tag,

            cr_read_in           => cr_read_valid,
            cr_write_in          => cr_write_valid,
            cr_bypass            => cr_bypass,

            ov_read_in           => ov_read_valid,
            ov_write_in          => ov_write_valid,

            valid_out   => control_valid_out,
            stopped_out => stopped_out,

            gpr_bypass_a => gpr_a_bypass,
            gpr_bypass_b => gpr_b_bypass,
            gpr_bypass_c => gpr_c_bypass,

            instr_tag_out => instr_tag
            );

    deferred <= dc2.e.valid and busy_in;

    decode2_0: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or flush_in = '1' then
                dc2 <= reg_type_init;
            elsif deferred = '0' then
                if dc2in.e.valid = '1' then
                    report "execute " & to_hstring(dc2in.e.nia) &
                        " tag=" & integer'image(dc2in.e.instr_tag.tag) & std_ulogic'image(dc2in.e.instr_tag.valid);
                end if;
                dc2 <= dc2in;
            end if;
        end if;
    end process;

    c_out.read <= d_in.decode.input_cr;

    decode2_addrs: process(all)
    begin
        decoded_reg_a <= decode_input_reg_init;
        decoded_reg_b <= decode_input_reg_init;
        decoded_reg_c <= decode_input_reg_init;
        decoded_reg_o <= decode_output_reg_init;
        if d_in.valid = '1' then
            decoded_reg_a <= decode_input_reg_a (d_in.decode.input_reg_a, d_in.insn, d_in.ispr1, d_in.nia);
            decoded_reg_b <= decode_input_reg_b (d_in.decode.input_reg_b, d_in.insn, d_in.ispr2);
            decoded_reg_c <= decode_input_reg_c (d_in.decode.input_reg_c, d_in.insn);
            decoded_reg_o <= decode_output_reg (d_in.decode.output_reg_a, d_in.insn, d_in.ispro);
        end if;

        r_out.read1_enable <= decoded_reg_a.reg_valid;
        r_out.read1_reg    <= decoded_reg_a.reg;
        r_out.read2_enable <= decoded_reg_b.reg_valid;
        r_out.read2_reg    <= decoded_reg_b.reg;
        r_out.read3_enable <= decoded_reg_c.reg_valid;
        r_out.read3_reg    <= decoded_reg_c.reg;

    end process;

    decode2_1: process(all)
        variable v : reg_type;
        variable length : std_ulogic_vector(3 downto 0);
        variable op : insn_type_t;
        variable valid_in : std_ulogic;
    begin
        v := dc2;

        valid_in := d_in.valid or dc2.busy;

        if dc2.busy = '0' then
            v.e := Decode2ToExecute1Init;

            if d_in.valid = '1' then
                v.prev_sgl := dc2.sgl_pipe;
                v.sgl_pipe := d_in.decode.sgl_pipe;
            end if;

            v.e.input_cr := d_in.decode.input_cr;
            v.e.output_cr := d_in.decode.output_cr;

            -- Work out whether XER SO/OV/OV32 bits are set
            -- or used by this instruction
            v.e.rc := decode_rc(d_in.decode.rc, d_in.insn);
            v.e.output_xer := d_in.decode.output_carry;
            v.input_ov := d_in.decode.output_carry;
            v.output_ov := '0';
            if d_in.decode.input_carry = OV then
                v.input_ov := '1';
                v.output_ov := '1';
            end if;
            if v.e.rc = '1' and d_in.decode.facility /= FPU then
                v.input_ov := '1';
            end if;
            case d_in.decode.insn_type is
                when OP_ADD | OP_MUL_L64 | OP_DIV | OP_DIVE =>
                    -- OE field is valid in OP_ADD/OP_MUL_L64 with major opcode 31 only
                    if d_in.insn(31 downto 26) = "011111" and insn_oe(d_in.insn) = '1' then
                        v.e.oe := '1';
                        v.e.output_xer := '1';
                        v.output_ov := '1';
                        v.input_ov := '1';      -- need SO state if setting OV to 0
                    end if;
                when OP_MFSPR =>
                    if decode_spr_num(d_in.insn) = SPR_XER then
                        v.input_ov := '1';
                    end if;
                when OP_MTSPR =>
                    if decode_spr_num(d_in.insn) = SPR_XER then
                        v.e.output_xer := '1';
                        v.output_ov := '1';
                    end if;
                when OP_CMP | OP_MCRXRX =>
                    v.input_ov := '1';
                when others =>
            end case;

            v.reg_a_valid := decoded_reg_a.reg_valid;
            v.reg_b_valid := decoded_reg_b.reg_valid;
            v.reg_c_valid := decoded_reg_c.reg_valid;
            v.reg_o_valid := decoded_reg_o.reg_valid;

            if d_in.decode.lr = '1' then
                v.e.lr := insn_lk(d_in.insn);
                -- b and bc have even major opcodes; bcreg is considered absolute
                v.e.br_abs := insn_aa(d_in.insn) or d_in.insn(26);
            end if;
            op := d_in.decode.insn_type;

            v.repeat := d_in.decode.repeat;
            if d_in.decode.repeat /= NONE then
                v.e.repeat := '1';
            elsif v.e.lr = '1' and decoded_reg_a.reg_valid = '1' then
                -- bcl/bclrl/bctarl that needs to write both CTR and LR has to be doubled
                v.e.repeat := '1';
            end if;

            v.e.spr_select := d_in.spr_info;

            case d_in.decode.length is
                when is1B =>
                    length := "0001";
                when is2B =>
                    length := "0010";
                when is4B =>
                    length := "0100";
                when is8B =>
                    length := "1000";
                when NONE =>
                    length := "0000";
            end case;

            -- execute unit
            v.e.nia := d_in.nia;
            v.e.unit := d_in.decode.unit;
            v.e.fac := d_in.decode.facility;
            v.e.read_reg1 := decoded_reg_a.reg;
            v.e.read_reg2 := decoded_reg_b.reg;
            v.e.read_reg3 := decoded_reg_c.reg;
            v.e.write_reg := decoded_reg_o.reg;
            v.e.write_reg_enable := decoded_reg_o.reg_valid;
            v.e.invert_a := d_in.decode.invert_a;
            v.e.addm1 := '0';
            v.e.insn_type := op;
            v.e.invert_out := d_in.decode.invert_out;
            v.e.input_carry := d_in.decode.input_carry;
            v.e.output_carry := d_in.decode.output_carry;
            v.e.is_32bit := d_in.decode.is_32bit;
            v.e.is_signed := d_in.decode.is_signed;
            v.e.insn := d_in.insn;
            v.e.data_len := length;
            v.e.byte_reverse := d_in.decode.byte_reverse;
            v.e.sign_extend := d_in.decode.sign_extend;
            v.e.update := d_in.decode.update;
            v.e.reserve := d_in.decode.reserve;
            v.e.br_pred := d_in.br_pred;
            v.e.result_sel := result_select(op);
            v.e.sub_select := subresult_select(op);
            if op = OP_BC or op = OP_BCREG then
                if d_in.insn(23) = '0' and
                    not (d_in.decode.insn_type = OP_BCREG and d_in.insn(10) = '0') then
                    -- decrement CTR if BO(2) = 0 and not bcctr
                    v.e.addm1 := '1';
                    v.e.result_sel := "000";        -- select adder output
                end if;
            end if;
            if op = OP_MFSPR then
                if is_fast_spr(d_in.ispr1) = '1' then
                    v.e.result_sel := "000";        -- adder_result, effectively a_in
                elsif d_in.spr_info.valid = '0' then
                    -- Privileged mfspr to invalid/unimplemented SPR numbers
                    -- writes the contents of RT back to RT (i.e. it's a no-op)
                    v.e.result_sel := "001";        -- logical_result
                elsif d_in.spr_info.ispmu = '1' then
                    v.e.result_sel := "100";        -- pmuspr_result
                end if;
            end if;

        elsif dc2.e.valid = '1' then
            -- dc2.busy = 1 and dc2.e.valid = 1, thus this must be a repeated instruction.
            -- Set up for the second iteration (if deferred = 1 this will all be ignored)
            v.e.second := '1';
            case dc2.repeat is
                when DUPD =>
                    -- update-form loads, 2nd instruction writes RA
                    v.e.write_reg := dc2.e.read_reg1;
                when NONE =>
                    -- bcl/bclrl/bctarl that needs to write both CTR and LR
                    v.e.write_reg(0) := '0';    -- point to LR
                    v.e.result_sel := "110";    -- select NIA (to go to LR)
                when others =>
            end case;
        end if;

        -- issue control
        control_valid_in <= valid_in;
        control_serialize <= v.sgl_pipe or v.prev_sgl;

        gpr_write_valid <= v.reg_o_valid;
        gpr_write <= v.e.write_reg;

        gpr_a_read_valid <= v.reg_a_valid;
        gpr_a_read <= v.e.read_reg1;

        gpr_b_read_valid <= v.reg_b_valid;
        gpr_b_read <= v.e.read_reg2;

        gpr_c_read_valid <= v.reg_c_valid;
        gpr_c_read <= v.e.read_reg3;

        cr_write_valid <= v.e.output_cr or v.e.rc;
        -- Since ops that write CR only write some of the fields,
        -- any op that writes CR effectively also reads it.
        cr_read_valid <= cr_write_valid or v.e.input_cr;

        ov_read_valid <= v.input_ov;
        ov_write_valid <= v.output_ov;

        -- See if any of the operands can get their value via the bypass path.
        if dc2.busy = '0' or gpr_a_bypass /= "00" then
            case gpr_a_bypass is
                when "01" =>
                    v.e.read_data1 := execute_bypass.data;
                when "10" =>
                    v.e.read_data1 := execute2_bypass.data;
                when "11" =>
                    v.e.read_data1 := writeback_bypass.data;
                when others =>
                    if decoded_reg_a.reg_valid = '1' then
                        v.e.read_data1 := r_in.read1_data;
                    else
                        v.e.read_data1 := decoded_reg_a.data;
                    end if;
            end case;
        end if;
        if dc2.busy = '0' or gpr_b_bypass /= "00" then
            case gpr_b_bypass is
                when "01" =>
                    v.e.read_data2 := execute_bypass.data;
                when "10" =>
                    v.e.read_data2 := execute2_bypass.data;
                when "11" =>
                    v.e.read_data2 := writeback_bypass.data;
                when others =>
                    if decoded_reg_b.reg_valid = '1' then
                        v.e.read_data2 := r_in.read2_data;
                    else
                        v.e.read_data2 := decoded_reg_b.data;
                    end if;
            end case;
        end if;
        if dc2.busy = '0' or gpr_c_bypass /= "00" then
            case gpr_c_bypass is
                when "01" =>
                    v.e.read_data3 := execute_bypass.data;
                when "10" =>
                    v.e.read_data3 := execute2_bypass.data;
                when "11" =>
                    v.e.read_data3 := writeback_bypass.data;
                when others =>
                    if decoded_reg_c.reg_valid = '1' then
                        v.e.read_data3 := r_in.read3_data;
                    else
                        v.e.read_data3 := decoded_reg_c.data;
                    end if;
            end case;
        end if;

        case cr_bypass is
            when "10" =>
                v.e.cr := execute_cr_bypass.data;
            when "11" =>
                v.e.cr := execute2_cr_bypass.data;
            when others =>
                v.e.cr := c_in.read_cr_data;
        end case;
        v.e.xerc := c_in.read_xerc_data;

        v.e.valid := control_valid_out;
        v.e.instr_tag := instr_tag;
        v.busy := valid_in and (not control_valid_out or (v.e.repeat and not v.e.second));

        stall_out <= dc2.busy or deferred;

        -- Update registers
        dc2in <= v;

        -- Update outputs
        e_out <= dc2.e;
    end process;

    d2_log: if LOG_LENGTH > 0 generate
        signal log_data : std_ulogic_vector(9 downto 0);
    begin
        dec2_log : process(clk)
        begin
            if rising_edge(clk) then
                log_data <= dc2.e.nia(5 downto 2) &
                            dc2.e.valid &
                            stopped_out &
                            stall_out &
                            (gpr_a_bypass(1) xor gpr_a_bypass(0)) &
                            (gpr_b_bypass(1) xor gpr_b_bypass(0)) &
                            (gpr_c_bypass(1) xor gpr_c_bypass(0));
            end if;
        end process;
        log_out <= log_data;
    end generate;

end architecture behaviour;
