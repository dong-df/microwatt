library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.decode_types.all;
use work.common.all;
use work.insn_helpers.all;
use work.helpers.all;

-- 2 cycle LSU
-- We calculate the address in the first cycle

entity loadstore1 is
    generic (
        HAS_FPU : boolean := true;
        -- Non-zero to enable log data collection
        LOG_LENGTH : natural := 0
        );
    port (
        clk   : in std_ulogic;
        rst   : in std_ulogic;

        l_in  : in Execute1ToLoadstore1Type;
        e_out : out Loadstore1ToExecute1Type;
        l_out : out Loadstore1ToWritebackType;

        d_out : out Loadstore1ToDcacheType;
        d_in  : in DcacheToLoadstore1Type;

        m_out : out Loadstore1ToMmuType;
        m_in  : in MmuToLoadstore1Type;

        dc_stall  : in std_ulogic;

        events  : out Loadstore1EventType;

        -- Access to SPRs from core_debug module
        dbg_spr_req   : in std_ulogic;
        dbg_spr_ack   : out std_ulogic;
        dbg_spr_addr  : in std_ulogic_vector(1 downto 0);
        dbg_spr_data  : out std_ulogic_vector(63 downto 0);

        log_out : out std_ulogic_vector(9 downto 0)
        );
end loadstore1;

architecture behave of loadstore1 is

    -- State machine for unaligned loads/stores
    type state_t is (IDLE,              -- ready for instruction
                     MMU_WAIT           -- waiting for MMU to finish doing something
                     );

    constant num_dawr : positive := 2;

    type byte_index_t is array(0 to 7) of unsigned(2 downto 0);
    subtype byte_trim_t is std_ulogic_vector(1 downto 0);
    type trim_ctl_t is array(0 to 7) of byte_trim_t;

    type request_t is record
        valid        : std_ulogic;
        dc_req       : std_ulogic;
        load         : std_ulogic;
        store        : std_ulogic;
        flush        : std_ulogic;
        touch        : std_ulogic;
        sync         : std_ulogic;
        tlbie        : std_ulogic;
        dcbz         : std_ulogic;
        hashst       : std_ulogic;
        hashcmp      : std_ulogic;
        read_spr     : std_ulogic;
        write_spr    : std_ulogic;
        mmu_op       : std_ulogic;
        instr_fault  : std_ulogic;
        do_update    : std_ulogic;
        mode_32bit   : std_ulogic;
        prefixed     : std_ulogic;
	addr         : std_ulogic_vector(63 downto 0);
        byte_sel     : std_ulogic_vector(7 downto 0);
        second_bytes : std_ulogic_vector(7 downto 0);
	store_data   : std_ulogic_vector(63 downto 0);
        instr_tag    : instr_tag_t;
	write_reg    : gspr_index_t;
	length       : std_ulogic_vector(3 downto 0);
        elt_length   : std_ulogic_vector(3 downto 0);
	byte_reverse : std_ulogic;
        brev_mask    : unsigned(2 downto 0);
	sign_extend  : std_ulogic;
	update       : std_ulogic;
	xerc         : xer_common_t;
        reserve      : std_ulogic;
        atomic_qw    : std_ulogic;
        atomic_first : std_ulogic;
        atomic_last  : std_ulogic;
        rc           : std_ulogic;
        nc           : std_ulogic;              -- non-cacheable access
        virt_mode    : std_ulogic;
        priv_mode    : std_ulogic;
        load_sp      : std_ulogic;
        sprsel       : std_ulogic_vector(3 downto 0);
        ric          : std_ulogic_vector(1 downto 0);
        is_slbia     : std_ulogic;
        align_intr   : std_ulogic;
        dawr_intr    : std_ulogic;
        dword_index  : std_ulogic;
        two_dwords   : std_ulogic;
        incomplete   : std_ulogic;
        ea_valid     : std_ulogic;
    end record;
    constant request_init : request_t := (addr => (others => '0'),
                                          byte_sel => x"00", second_bytes => x"00",
                                          store_data => (others => '0'), instr_tag => instr_tag_init,
                                          write_reg => 6x"00", length => x"0",
                                          elt_length => x"0", brev_mask => "000",
                                          xerc => xerc_init,
                                          sprsel => "0000", ric => "00",
                                          others => '0');

    type reg_stage1_t is record
        req : request_t;
        busy : std_ulogic;
        issued : std_ulogic;
        addr0 : std_ulogic_vector(63 downto 0);
        dawr_ll : std_ulogic_vector(num_dawr-1 downto 0);
        dawr_ul : std_ulogic_vector(num_dawr-1 downto 0);
        dawr_ud : std_ulogic;
    end record;

    type reg_stage2_t is record
        req        : request_t;
        byte_index : byte_index_t;
        use_second : std_ulogic_vector(7 downto 0);
        busy       : std_ulogic;
        wait_dc    : std_ulogic;
        wait_mmu   : std_ulogic;
        one_cycle  : std_ulogic;
        wr_sel     : std_ulogic_vector(1 downto 0);
        addr0      : std_ulogic_vector(63 downto 0);
        sprsel     : std_ulogic_vector(3 downto 0);
        dbg_spr    : std_ulogic_vector(63 downto 0);
        dbg_spr_ack: std_ulogic;
    end record;

    type dawr_array_t is array(0 to num_dawr - 1) of std_ulogic_vector(63 downto 3);
    type dawrx_array_t is array(0 to num_dawr - 1) of std_ulogic_vector(15 downto 0);

    type reg_stage3_t is record
        state        : state_t;
        complete     : std_ulogic;
        instr_tag    : instr_tag_t;
        write_enable : std_ulogic;
	write_reg    : gspr_index_t;
        write_data   : std_ulogic_vector(63 downto 0);
        rc           : std_ulogic;
        xerc         : xer_common_t;
        store_done   : std_ulogic;
        load_data    : std_ulogic_vector(63 downto 0);
        dar          : std_ulogic_vector(63 downto 0);
        dsisr        : std_ulogic_vector(31 downto 0);
        ld_sp_data   : std_ulogic_vector(31 downto 0);
        ld_sp_nz     : std_ulogic;
        ld_sp_lz     : std_ulogic_vector(5 downto 0);
        stage1_en    : std_ulogic;
        interrupt    : std_ulogic;
        intr_vec     : integer range 0 to 16#fff#;
        srr1         : std_ulogic_vector(15 downto 0);
        events       : Loadstore1EventType;
        dawr         : dawr_array_t;
        dawrx        : dawrx_array_t;
        dawr_uplim   : dawr_array_t;
        dawr_upd     : std_ulogic;
    end record;

    signal req_in   : request_t;
    signal r1, r1in : reg_stage1_t;
    signal r2, r2in : reg_stage2_t;
    signal r3, r3in : reg_stage3_t;

    signal flush    : std_ulogic;
    signal busy     : std_ulogic;
    signal complete : std_ulogic;
    signal flushing : std_ulogic;

    signal store_sp_data : std_ulogic_vector(31 downto 0);
    signal load_dp_data  : std_ulogic_vector(63 downto 0);
    signal store_data    : std_ulogic_vector(63 downto 0);

    signal stage1_req          : request_t;
    signal stage1_dcreq        : std_ulogic;
    signal stage1_dreq         : std_ulogic;
    signal stage1_dawr_match   : std_ulogic;

    type hw_array_4 is array(0 to 3) of std_ulogic_vector(15 downto 0);
    type hw_array_8 is array(0 to 7) of std_ulogic_vector(15 downto 0);

    type hash_reg_t is record
        active : std_ulogic;
        done   : std_ulogic;
        step   : unsigned(2 downto 0);
        z0     : std_ulogic_vector(30 downto 0);
        key    : hw_array_4;
        xleft  : hw_array_4;
        xright : hw_array_4;
    end record;
    constant hash_reg_init : hash_reg_t := (
        active => '0', done => '0', step => "000", z0 => (others => '0'),
        key => (others => (others => '0')),
        xleft => (others => (others => '0')), xright => (others => (others => '0')));

    signal hash_r      : hash_reg_t;
    signal hash_rin    : hash_reg_t;
    signal hash_start  : std_ulogic;
    signal hash_result : std_ulogic_vector(63 downto 0);

    -- Generate byte enables from sizes
    function length_to_sel(length : in std_logic_vector(3 downto 0)) return std_ulogic_vector is
    begin
        case length is
            when "0001" =>
                return "00000001";
            when "0010" =>
                return "00000011";
            when "0100" =>
                return "00001111";
            when "1000" =>
                return "11111111";
            when others =>
                return "00000000";
        end case;
    end function length_to_sel;

    -- Calculate byte enables
    -- This returns 16 bits, giving the select signals for two transfers,
    -- to account for unaligned loads or stores
    function xfer_data_sel(size : in std_logic_vector(3 downto 0);
                           address : in std_logic_vector(2 downto 0))
	return std_ulogic_vector is
        variable longsel : std_ulogic_vector(15 downto 0);
    begin
        if is_X(address) then
            longsel := (others => 'X');
            return longsel;
        else
            longsel := "00000000" & length_to_sel(size);
            return std_ulogic_vector(shift_left(unsigned(longsel),
                                                to_integer(unsigned(address))));
        end if;
    end function xfer_data_sel;

    -- 23-bit right shifter for DP -> SP float conversions
    function shifter_23r(frac: std_ulogic_vector(22 downto 0); shift: unsigned(4 downto 0))
        return std_ulogic_vector is
        variable fs1   : std_ulogic_vector(22 downto 0);
        variable fs2   : std_ulogic_vector(22 downto 0);
    begin
        case shift(1 downto 0) is
            when "00" =>
                fs1 := frac;
            when "01" =>
                fs1 := '0' & frac(22 downto 1);
            when "10" =>
                fs1 := "00" & frac(22 downto 2);
            when others =>
                fs1 := "000" & frac(22 downto 3);
        end case;
        case shift(4 downto 2) is
            when "000" =>
                fs2 := fs1;
            when "001" =>
                fs2 := x"0" & fs1(22 downto 4);
            when "010" =>
                fs2 := x"00" & fs1(22 downto 8);
            when "011" =>
                fs2 := x"000" & fs1(22 downto 12);
            when "100" =>
                fs2 := x"0000" & fs1(22 downto 16);
            when others =>
                fs2 := x"00000" & fs1(22 downto 20);
        end case;
        return fs2;
    end;

    -- 23-bit left shifter for SP -> DP float conversions
    function shifter_23l(frac: std_ulogic_vector(22 downto 0); shift: unsigned(4 downto 0))
        return std_ulogic_vector is
        variable fs1   : std_ulogic_vector(22 downto 0);
        variable fs2   : std_ulogic_vector(22 downto 0);
    begin
        case shift(1 downto 0) is
            when "00" =>
                fs1 := frac;
            when "01" =>
                fs1 := frac(21 downto 0) & '0';
            when "10" =>
                fs1 := frac(20 downto 0) & "00";
            when others =>
                fs1 := frac(19 downto 0) & "000";
        end case;
        case shift(4 downto 2) is
            when "000" =>
                fs2 := fs1;
            when "001" =>
                fs2 := fs1(18 downto 0) & x"0" ;
            when "010" =>
                fs2 := fs1(14 downto 0) & x"00";
            when "011" =>
                fs2 := fs1(10 downto 0) & x"000";
            when "100" =>
                fs2 := fs1(6 downto 0) & x"0000";
            when others =>
                fs2 := fs1(2 downto 0) & x"00000";
        end case;
        return fs2;
    end;

    function dawrx_match_enable(dawrx : std_ulogic_vector(15 downto 0); virt_mode : std_ulogic;
                                priv_mode : std_ulogic; is_store : std_ulogic)
        return boolean is
    begin
        -- check PRIVM field; note priv_mode = '1' implies hypervisor mode
        if (priv_mode = '0' and dawrx(0) = '0') or (priv_mode = '1' and dawrx(2) = '0') then
            return false;
        end if;
        -- check WT/WTI fields
        if dawrx(3) = '0' and virt_mode /= dawrx(4) then
            return false;
        end if;
        -- check DW/DR fields
        if (is_store = '0' and dawrx(5) = '0') or (is_store = '1' and dawrx(6) = '0') then
            return false;
        end if;
        return true;
    end;

begin
    loadstore1_reg: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                r1.busy <= '0';
                r1.issued <= '0';
                r1.req.valid <= '0';
                r1.req.dc_req <= '0';
                r1.req.incomplete <= '0';
                r1.req.tlbie <= '0';
                r1.req.is_slbia <= '0';
                r1.req.instr_fault <= '0';
                r1.req.load <= '0';
                r1.req.priv_mode <= '0';
                r1.req.sprsel <= "0000";
                r1.req.ric <= "00";
                r1.req.xerc <= xerc_init;
                r1.dawr_ll <= (others => '0');
                r1.dawr_ul <= (others => '0');
                r1.dawr_ud <= '0';

                r2.req.valid <= '0';
                r2.busy <= '0';
                r2.req.tlbie <= '0';
                r2.req.is_slbia <= '0';
                r2.req.instr_fault <= '0';
                r2.req.load <= '0';
                r2.req.priv_mode <= '0';
                r2.req.sprsel <= "0000";
                r2.req.ric <= "00";
                r2.req.xerc <= xerc_init;

                r2.wait_dc <= '0';
                r2.wait_mmu <= '0';
                r2.one_cycle <= '0';

                r3.dar <= (others => '0');
                r3.dsisr <= (others => '0');
                r3.state <= IDLE;
                r3.write_enable <= '0';
                r3.interrupt <= '0';
                r3.complete <= '0';
                r3.stage1_en <= '1';
                r3.events.load_complete <= '0';
                r3.events.store_complete <= '0';
                for i in 0 to num_dawr - 1 loop
                    r3.dawr(i) <= (others => '0');
                    r3.dawrx(i) <= (others => '0');
                    r3.dawr_uplim(i) <= (others => '0');
                end loop;
                r3.dawr_upd <= '0';
                flushing <= '0';
            else
                r1 <= r1in;
                r2 <= r2in;
                r3 <= r3in;
                flushing <= (flushing or (r1in.req.valid and
                                          (r1in.req.align_intr or r1in.req.dawr_intr))) and
                            not flush;
            end if;
            stage1_dreq <= stage1_dcreq;
            if d_in.valid = '1' then
                assert r2.req.valid = '1' and r2.req.dc_req = '1' and r3.state = IDLE severity failure;
            end if;
            if d_in.error = '1' then
                assert r2.req.valid = '1' and r2.req.dc_req = '1' and r3.state = IDLE severity failure;
            end if;
            if m_in.done = '1' or m_in.err = '1' then
                assert r2.req.valid = '1' and r3.state = MMU_WAIT severity failure;
            end if;
        end if;
    end process;

    ls_fp_conv: if HAS_FPU generate
        -- Convert DP data to SP for stfs
        dp_to_sp: process(all)
            variable exp   : unsigned(10 downto 0);
            variable frac  : std_ulogic_vector(22 downto 0);
            variable shift : unsigned(4 downto 0);
        begin
            store_sp_data(31) <= l_in.data(63);
            store_sp_data(30 downto 0) <= (others => '0');
            exp := unsigned(l_in.data(62 downto 52));
            if exp > 896 then
                store_sp_data(30) <= l_in.data(62);
                store_sp_data(29 downto 0) <= l_in.data(58 downto 29);
            elsif exp >= 874 then
                -- denormalization required
                frac := '1' & l_in.data(51 downto 30);
                shift := 0 - exp(4 downto 0);
                store_sp_data(22 downto 0) <= shifter_23r(frac, shift);
            end if;
        end process;

        -- Convert SP data to DP for lfs
        sp_to_dp: process(all)
            variable exp     : unsigned(7 downto 0);
            variable exp_dp  : unsigned(10 downto 0);
            variable exp_nz  : std_ulogic;
            variable exp_ao  : std_ulogic;
            variable frac    : std_ulogic_vector(22 downto 0);
            variable frac_shift : unsigned(4 downto 0);
        begin
            frac := r3.ld_sp_data(22 downto 0);
            exp := unsigned(r3.ld_sp_data(30 downto 23));
            exp_nz := or (r3.ld_sp_data(30 downto 23));
            exp_ao := and (r3.ld_sp_data(30 downto 23));
            frac_shift := (others => '0');
            if exp_ao = '1' then
                exp_dp := to_unsigned(2047, 11);    -- infinity or NaN
            elsif exp_nz = '1' then
                exp_dp := 896 + resize(exp, 11);    -- finite normalized value
            elsif r3.ld_sp_nz = '0' then
                exp_dp := to_unsigned(0, 11);       -- zero
            else
                -- denormalized SP operand, need to normalize
                exp_dp := 896 - resize(unsigned(r3.ld_sp_lz), 11);
                frac_shift := unsigned(r3.ld_sp_lz(4 downto 0)) + 1;
            end if;
            load_dp_data(63) <= r3.ld_sp_data(31);
            load_dp_data(62 downto 52) <= std_ulogic_vector(exp_dp);
            load_dp_data(51 downto 29) <= shifter_23l(frac, frac_shift);
            load_dp_data(28 downto 0) <= (others => '0');
        end process;
    end generate;

    -- This does the HashDigest computation from ISA Book I section 3.3.17
    -- in 8 cycles.  In each cycle it does 4 steps of key expansion, and
    -- 4 rounds of cipher for each of 4 lanes.
    loadstore_hash_reg: process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                hash_r <= hash_reg_init;
            else
                if hash_r.done = '1' then
                    report "hash_result = " & to_hstring(hash_result);
                end if;
                hash_r <= hash_rin;
            end if;
        end if;
    end process;

    loadstore_hash_comb: process(all)
        variable hv     : hash_reg_t;
        variable keys   : hw_array_8;
        variable xl, xr : std_ulogic_vector(15 downto 0);
        variable z, t   : std_ulogic_vector(15 downto 0);
        variable fx     : std_ulogic_vector(15 downto 0);
        variable ra, rb : std_ulogic_vector(63 downto 0);
        variable key    : std_ulogic_vector(63 downto 0);
        variable j, k   : integer;
    begin
        hv := hash_r;
        hv.done := '0';
        if hash_r.active = '1' then
            -- Initialize keys to avoid yosys/ghdl incorrectly inferring latches
            for i in 0 to 7 loop
                keys(i) := (others => '0');
            end loop;
            -- generate the next 4 key words
            for i in 0 to 3 loop
                keys(i) := hash_r.key(i);
            end loop;
            for i in 4 to 7 loop
                z := 15x"0" & hash_r.z0(34 - i);
                t := (keys(i-1)(2 downto 0) & keys(i-1)(15 downto 3)) xor keys(i-3);
                keys(i) := x"fffc" xor z xor keys(i-4) xor t xor (t(0) & t(15 downto 1));
                hv.key(i-4) := keys(i);
            end loop;
            hv.z0 := hash_r.z0(26 downto 0) & "0000";
            -- do 4 rounds for each of 4 lanes
            for lane in 0 to 3 loop
                xr := hash_r.xright(lane);
                xl := hash_r.xleft(lane);
                for i in 0 to 3 loop
                    fx := ((xl(14 downto 0) & xl(15)) and (xl(7 downto 0) & xl(15 downto 8))) xor
                          (xl(13 downto 0) & xl(15 downto 14));
                    t := xr xor fx xor hash_r.key((i + lane) mod 4);
                    xr := xl;
                    xl := t;
                end loop;
                hv.xright(lane) := xr;
                hv.xleft(lane) := xl;
            end loop;
            hv.step := hash_r.step + 1;
            if hash_r.step = 3x"7" then
                hv.active := '0';
                hv.done := '1';
            end if;
        elsif hash_start = '1' then
            -- start a new hash process
            hv.z0 := 31x"7D12B0E6";     -- 0xFA2561CD >> 1
            ra := l_in.addr1;
            rb := l_in.data;
            key := l_in.hashkey;
            for lane in 0 to 3 loop
                j := lane * 16;
                k := (3 - lane) * 16;
                hv.xright(lane)(15 downto 8) := rb(j + 7 downto j);
                hv.xright(lane)(7 downto 0)  := ra(k + 15 downto k + 8);
                hv.xleft(lane)(15 downto 8)  := rb(j + 15 downto j + 8);
                hv.xleft(lane)(7 downto 0)   := ra(k + 7 downto k);
            end loop;
            for i in 0 to 3 loop
                j := (3 - i) * 16;
                hv.key(i) := key(j + 15 downto j);
            end loop;
            hv.step := "000";
            hv.active := '1';
        end if;
        -- only valid when hash_r.done = 1
        hash_result <= (hash_r.xright(0) & hash_r.xleft(0) & hash_r.xright(1) & hash_r.xleft(1)) xor
                       (hash_r.xright(2) & hash_r.xleft(2) & hash_r.xright(3) & hash_r.xleft(3));

        hash_rin <= hv;
    end process;

    -- Translate a load/store instruction into the internal request format
    -- XXX this should only depend on l_in, but actually depends on
    -- r1.addr0 as well (in the l_in.second = 1 case).
    loadstore1_in: process(all)
        variable v : request_t;
        variable lsu_sum : std_ulogic_vector(63 downto 0);
        variable brev_lenm1 : unsigned(2 downto 0);
        variable long_sel : std_ulogic_vector(15 downto 0);
        variable addr : std_ulogic_vector(63 downto 0);
        variable sprn : std_ulogic_vector(9 downto 0);
        variable misaligned : std_ulogic;
        variable addr_mask : std_ulogic_vector(2 downto 0);
        variable hash_nop : std_ulogic;
    begin
        v := request_init;
        sprn := l_in.insn(15 downto 11) & l_in.insn(20 downto 16);

        v.valid := l_in.valid;
        v.instr_tag := l_in.instr_tag;
        v.mode_32bit := l_in.mode_32bit;
        v.prefixed := l_in.prefixed;
        v.write_reg := l_in.write_reg;
        v.length := l_in.length;
        v.elt_length := l_in.length;
        v.byte_reverse := l_in.byte_reverse;
        v.sign_extend := l_in.sign_extend;
        v.update := l_in.update;
        v.xerc := l_in.xerc;
        v.reserve := l_in.reserve;
        v.rc := l_in.rc;
        v.nc := l_in.ci;
        v.virt_mode := l_in.virt_mode;
        v.priv_mode := l_in.priv_mode;
        v.ric := l_in.insn(19 downto 18);
        if sprn(8 downto 7) = "01" then
            -- debug registers DAWR[X][01]
            v.sprsel := "01" & sprn(3) & sprn(0);
        elsif sprn(1) = '1' then
            -- DSISR and DAR
            v.sprsel := "001" & sprn(0);
        else
            -- PID and PTCR
            v.sprsel := "100" & sprn(8);
        end if;

        lsu_sum := std_ulogic_vector(unsigned(l_in.addr1) + unsigned(l_in.addr2));

        if HAS_FPU and l_in.is_32bit = '1' then
            v.store_data := x"00000000" & store_sp_data;
        else
            v.store_data := l_in.data;
        end if;

        addr := lsu_sum;
        if l_in.second = '1' then
            -- for an update-form load, use the previous address
            -- as the value to write back to RA.
            -- for a quadword load or store, use with the previous
            -- address + 8.
            addr := std_ulogic_vector(unsigned(r1.addr0(63 downto 3)) + not l_in.update) &
                    r1.addr0(2 downto 0);
        end if;
        if l_in.mode_32bit = '1' then
            addr(63 downto 32) := (others => '0');
        end if;
        v.addr := addr;
        v.ea_valid := l_in.valid;

        -- XXX Temporary hack. Mark the op as non-cachable if the address
        -- is the form 0xc------- for a real-mode access.
        if addr(31 downto 28) = "1100" and l_in.virt_mode = '0' then
            v.nc := '1';
        end if;

        addr_mask := std_ulogic_vector(unsigned(l_in.length(2 downto 0)) - 1);

        -- Do length_to_sel and work out if we are doing 2 dwords
        long_sel := xfer_data_sel(l_in.length, addr(2 downto 0));
        v.byte_sel := long_sel(7 downto 0);
        v.second_bytes := long_sel(15 downto 8);
        if long_sel(15 downto 8) /= "00000000" then
            v.two_dwords := '1';
        end if;

        -- check alignment for larx/stcx
        misaligned := or (addr_mask and addr(2 downto 0));
        if l_in.repeat = '1' and l_in.update = '0' and addr(3) /= l_in.second then
            misaligned := '1';
        end if;
        v.align_intr := (l_in.reserve or (l_in.hash and l_in.hash_enable)) and misaligned;

        v.atomic_first := not misaligned and not l_in.second;
        v.atomic_last := not misaligned and (l_in.second or not l_in.repeat);

        -- is this a quadword load or store? i.e. lq plq stq pstq lqarx stqcx.
        if l_in.repeat = '1' and l_in.update = '0' then
            if misaligned = '0' then
                -- Since the access is aligned we have to do it atomically
                v.atomic_qw := '1';
            else
                -- We require non-prefixed lq in LE mode to be aligned in order
                -- to avoid the case where RA = RT+1 and the second access faults
                -- after the first has overwritten RA.
                if l_in.op = OP_LOAD and l_in.byte_reverse = '0' and l_in.prefixed = '0' then
                    v.align_intr := '1';
                end if;
            end if;
        end if;

        hash_nop := '0';
        case l_in.op is
            when OP_SYNC =>
                v.sync := '1';
                v.ea_valid := '0';
            when OP_STORE =>
                v.store := '1';
                if l_in.length = "0000" then
                    v.touch := '1';
                end if;
                v.hashst := l_in.hash;
                hash_nop := not l_in.hash_enable;
            when OP_LOAD =>
                if l_in.update = '0' or l_in.second = '0' then
                    v.load := '1';
                    if HAS_FPU and l_in.is_32bit = '1' then
                        -- Allow an extra cycle for SP->DP precision conversion
                        v.load_sp := '1';
                    end if;
                    if l_in.length = "0000" then
                        v.touch := '1';
                    end if;
                else
                    -- write back address to RA
                    v.do_update := '1';
                end if;
                v.hashcmp := l_in.hash;
                hash_nop := not l_in.hash_enable;
            when OP_DCBF =>
                v.load := '1';
                v.flush := '1';
            when OP_DCBZ =>
                v.dcbz := '1';
            when OP_TLBIE =>
                v.tlbie := '1';
                v.is_slbia := l_in.insn(7);
                v.mmu_op := '1';
            when OP_MFSPR =>
                v.read_spr := '1';
                v.ea_valid := '0';
            when OP_MTSPR =>
                v.write_spr := '1';
                v.mmu_op := not (sprn(1) or sprn(2));
                v.ea_valid := '0';
            when OP_FETCH_FAILED =>
                -- send it to the MMU to do the radix walk
                v.instr_fault := '1';
                v.mmu_op := '1';
            when others =>
        end case;
        v.dc_req := l_in.valid and (v.load or v.store or v.sync or v.dcbz or v.tlbie) and
                    not v.align_intr and not hash_nop;
        v.incomplete := v.dc_req and v.two_dwords;

        -- Work out controls for load and store formatting
        brev_lenm1 := "000";
        if v.byte_reverse = '1' then
            brev_lenm1 := unsigned(l_in.length(2 downto 0)) - 1;
        end if;
        v.brev_mask := brev_lenm1;

        req_in <= v;
    end process;

    busy <= dc_stall or d_in.error or r1.busy or r2.busy;
    complete <= r2.one_cycle or (r2.wait_dc and d_in.valid) or r3.complete;

    -- Processing done in the first cycle of a load/store instruction
    loadstore1_1: process(all)
        variable v     : reg_stage1_t;
        variable req   : request_t;
        variable dcreq : std_ulogic;
        variable issue : std_ulogic;
        variable addr : std_ulogic_vector(63 downto 3);
        variable addl : unsigned(64 downto 3);
        variable addu : unsigned(64 downto 3);
    begin
        v := r1;
        issue := '0';
        dcreq := '0';
        hash_start <= '0';

        if r1.busy = '0' then
            req := req_in;
            req.valid := l_in.valid;
            if flushing = '1' then
                -- Make this a no-op request rather than simply invalid.
                -- It will never get to stage 3 since there is a request ahead of
                -- it with align_intr = 1.
                req.dc_req := '0';
            end if;
            issue := l_in.valid and req.dc_req;
            if l_in.valid = '1' then
                v.addr0 := req.addr;
            end if;
        else
            req := r1.req;
            if r1.req.dc_req = '1' and r1.issued = '0' then
                issue := '1';
            elsif r1.req.incomplete = '1' then
                -- construct the second request for a misaligned access
                req.dword_index := '1';
                req.incomplete := '0';
                req.addr := std_ulogic_vector(unsigned(r1.req.addr(63 downto 3)) + 1) & "000";
                if r1.req.mode_32bit = '1' then
                    req.addr(32) := '0';
                end if;
                req.byte_sel := r1.req.second_bytes;
                issue := '1';
            else
                -- For the lfs conversion cycle, leave the request valid
                -- for another cycle but with req.dc_req = 0.
                -- (In other words we insert an extra dummy request.)
                -- For an MMU request last cycle, we have nothing
                -- to do in this cycle, so make it invalid.
                if r1.req.load_sp = '0' then
                    req.valid := '0';
                end if;
                req.dc_req := '0';
            end if;
        end if;

        -- Do subtractions for DAWR0/1 matches
        for i in 0 to 1 loop
            addr := req.addr(63 downto 3);
            if req.priv_mode = '1' and r3.dawrx(i)(7) = '1' then
                -- HRAMMC=1 => trim top bit from address
                addr(63) := '0';
            end if;
            addl := unsigned('0' & addr) - unsigned('0' & r3.dawr(i));
            addu := unsigned('0' & r3.dawr_uplim(i)) - unsigned('0' & addr);
            v.dawr_ll(i) := addl(64);
            v.dawr_ul(i) := addu(64);
        end loop;
        v.dawr_ud := r3.dawr_upd;

        if flush = '1' then
            v.req.valid := '0';
            v.req.dc_req := '0';
            v.req.incomplete := '0';
            v.issued := '0';
            v.busy := '0';
        elsif (dc_stall or d_in.error or r2.busy) = '0' then
            -- we can change what's in r1 next cycle because the current thing
            -- in r1 will go into r2
            v.req := req;
            if issue = '1' and (req.hashst or req.hashcmp) = '1' then
                -- need to initiate and then wait for the hash computation
                hash_start <= not r1.busy;
                v.busy := not hash_r.done;
                if hash_r.done = '0' then
                    issue := '0';
                else
                    v.req.store_data := hash_result;
                end if;
            else
                v.busy := (issue and (req.incomplete or req.load_sp)) or (req.valid and req.mmu_op);
            end if;
            dcreq := issue;
            v.issued := issue;
        else
            -- pipeline is stalled
            if r1.issued = '1' and d_in.error = '1' then
                v.issued := '0';
                v.busy := '1';
            end if;
        end if;

        stage1_req <= req;
        stage1_dcreq <= dcreq;
        r1in <= v;
    end process;

    -- Processing done in the second cycle of a load/store instruction.
    -- Store data is formatted here and sent to the dcache.
    -- The request in r1 is sent to stage 3 if stage 3 will not be busy next cycle.
    loadstore1_2: process(all)
        variable v : reg_stage2_t;
        variable j : integer;
        variable k : unsigned(2 downto 0);
        variable kk : unsigned(3 downto 0);
        variable idx : unsigned(2 downto 0);
        variable byte_offset : unsigned(2 downto 0);
        variable interrupt : std_ulogic;
        variable dbg_spr_rd : std_ulogic;
        variable sprsel : std_ulogic_vector(3 downto 0);
        variable sprval : std_ulogic_vector(63 downto 0);
        variable dawr_match : std_ulogic;
    begin
        v := r2;

        -- Byte reversing and rotating for stores.
        -- Done in the second cycle (the cycle after l_in.valid = 1).
        byte_offset := unsigned(r1.addr0(2 downto 0));
        for i in 0 to 7 loop
            k := (to_unsigned(i, 3) - byte_offset) xor r1.req.brev_mask;
	    if is_X(k) then
		store_data(i * 8 + 7 downto i * 8) <= (others => 'X');
	    else
		j := to_integer(k) * 8;
		store_data(i * 8 + 7 downto i * 8) <= r1.req.store_data(j + 7 downto j);
	    end if;
        end loop;

        -- Test for DAWR0/1 matches
        dawr_match := '0';
        for i in 0 to 1 loop
            if r1.dawr_ll(i) = '0' and r1.dawr_ul(i) = '0' and r1.dawr_ud = '0' and
                dawrx_match_enable(r3.dawrx(i), r1.req.virt_mode,
                                   r1.req.priv_mode, r1.req.store) then
                dawr_match := r1.req.valid and r1.req.dc_req and not r3.dawr_upd and
                              not (r1.req.touch or r1.req.sync or r1.req.flush or r1.req.tlbie);
            end if;
        end loop;
        stage1_dawr_match <= dawr_match;

        dbg_spr_rd := dbg_spr_req and not (r1.req.valid and r1.req.read_spr);
        if dbg_spr_rd = '0' then
            sprsel := r1.req.sprsel;
        else
            sprsel := "00" & dbg_spr_addr;
        end if;
        if sprsel(3) = '1' then
            sprval := m_in.sprval;  -- MMU regs
        else
            case sprsel(2 downto 0) is
                when "100" =>
                    sprval := r3.dawr(0) & "000";
                when "101" =>
                    sprval := r3.dawr(1) & "000";
                when "110" =>
                    sprval := 48x"0" & r3.dawrx(0);
                when "111" =>
                    sprval := 48x"0" & r3.dawrx(1);
                when "010" =>
                    sprval := x"00000000" & r3.dsisr;
                when "011" =>
                    sprval := r3.dar;
                when others =>
                    sprval := (others => '0');
            end case;
        end if;
        if dbg_spr_req = '0' then
            v.dbg_spr_ack := '0';
        elsif dbg_spr_rd = '1' and r2.dbg_spr_ack = '0' then
            v.dbg_spr := sprval;
            v.dbg_spr_ack := '1';
        end if;

        if (dc_stall or d_in.error or r2.busy or l_in.e2stall) = '0' then
            if r1.req.valid = '0' or r1.issued = '1' or r1.req.dc_req = '0' then
                v.req := r1.req;
                v.addr0 := r1.addr0;
                v.req.store_data := store_data;
                v.req.dawr_intr := dawr_match;
                v.wait_dc := r1.req.valid and r1.req.dc_req and not r1.req.load_sp and
                             not r1.req.incomplete and not r1.req.hashcmp and not r1.req.tlbie;
                v.wait_mmu := r1.req.valid and r1.req.mmu_op;
                if r1.req.valid = '1' and (r1.req.align_intr or r1.req.hashcmp) = '1' then
                    v.busy := '1';
                    v.one_cycle := '0';
                else
                    v.busy := r1.req.valid and r1.req.mmu_op;
                    v.one_cycle := r1.req.valid and not (r1.req.dc_req or r1.req.mmu_op);
                end if;
                if r1.req.do_update = '1' or r1.req.store = '1' or r1.req.read_spr = '1' then
                    v.wr_sel := "00";
                elsif r1.req.load_sp = '1' then
                    v.wr_sel := "01";
                else
                    v.wr_sel := "10";
                end if;
                if r1.req.read_spr = '1' then
                    v.addr0 := sprval;
                end if;

                -- Work out load formatter controls for next cycle
                for i in 0 to 7 loop
                    idx := to_unsigned(i, 3) xor r1.req.brev_mask;
                    kk := ('0' & idx) + ('0' & byte_offset);
                    v.use_second(i) := kk(3);
                    v.byte_index(i) := kk(2 downto 0);
                end loop;
            else
                v.req.valid := '0';
                v.wait_dc := '0';
                v.wait_mmu := '0';
                v.one_cycle := '0';
            end if;
        end if;
        if r2.wait_mmu = '1' and m_in.done = '1' then
            if r2.req.mmu_op = '1' then
                v.req.valid := '0';
                v.busy := '0';
            end if;
            v.wait_mmu := '0';
        end if;
        if r2.busy = '1' and r2.wait_mmu = '0' then
            if r2.req.hashcmp = '0' or d_in.valid = '1' then
                v.busy := '0';
            end if;
        end if;

        interrupt := (r2.req.valid and r2.req.align_intr) or
                     (d_in.error and (d_in.cache_paradox or d_in.reserve_nc or r2.req.dawr_intr)) or
                     m_in.err;
        if interrupt = '1' then
            v.req.valid := '0';
            v.busy := '0';
            v.wait_dc := '0';
            v.wait_mmu := '0';
        elsif d_in.error = '1' then
            v.wait_mmu := '1';
            v.busy := '1';
        end if;

        r2in <= v;

        -- SPR values for core_debug
        dbg_spr_data <= r2.dbg_spr;
        dbg_spr_ack <= r2.dbg_spr_ack;
    end process;

    -- Processing done in the third cycle of a load/store instruction.
    -- At this stage we can do things that have side effects without
    -- fear of the instruction getting flushed.  This is the point at
    -- which requests get sent to the MMU.
    loadstore1_3: process(all)
        variable v             : reg_stage3_t;
        variable j             : integer;
        variable req           : std_ulogic;
        variable mmureq        : std_ulogic;
        variable mmu_mtspr     : std_ulogic;
        variable write_enable  : std_ulogic;
        variable write_data    : std_ulogic_vector(63 downto 0);
        variable do_update     : std_ulogic;
        variable done          : std_ulogic;
        variable exception     : std_ulogic;
        variable data_permuted : std_ulogic_vector(63 downto 0);
        variable data_trimmed  : std_ulogic_vector(63 downto 0);
        variable sprval        : std_ulogic_vector(63 downto 0);
        variable negative      : std_ulogic;
        variable dsisr         : std_ulogic_vector(31 downto 0);
        variable itlb_fault    : std_ulogic;
        variable trim_ctl      : trim_ctl_t;
        variable hashchk_trap  : std_ulogic;
    begin
        v := r3;

        req := '0';
        mmureq := '0';
        mmu_mtspr := '0';
        done := '0';
        exception := '0';
        dsisr := (others => '0');
        write_enable := '0';
        sprval := (others => '0');
        do_update := '0';
        v.complete := '0';
        v.srr1 := (others => '0');
        v.events := (others => '0');

        -- Evaluate DAWR upper limits after a clock edge
        v.dawr_upd := '0';
        if r3.dawr_upd = '1' then
            for i in 0 to num_dawr - 1 loop
                v.dawr_uplim(i) := std_ulogic_vector(unsigned(r3.dawr(i)) +
                                                     unsigned(r3.dawrx(i)(15 downto 10)));
            end loop;
        end if;

        -- load data formatting
        -- shift and byte-reverse data bytes
        for i in 0 to 7 loop
	    if is_X(r2.byte_index(i)) then
		data_permuted(i * 8 + 7 downto i * 8) := (others => 'X');
	    else
		j := to_integer(r2.byte_index(i)) * 8;
		data_permuted(i * 8 + 7 downto i * 8) := d_in.data(j + 7 downto j);
	    end if;
        end loop;

        -- Work out the sign bit for sign extension.
        -- For unaligned loads crossing two dwords, the sign bit is in the
        -- first dword for big-endian (byte_reverse = 1), or the second dword
        -- for little-endian.
        if r2.req.dword_index = '1' and r2.req.byte_reverse = '1' then
            negative := (r2.req.length(3) and r3.load_data(63)) or
                        (r2.req.length(2) and r3.load_data(31)) or
                        (r2.req.length(1) and r3.load_data(15)) or
                        (r2.req.length(0) and r3.load_data(7));
        else
            negative := (r2.req.length(3) and data_permuted(63)) or
                        (r2.req.length(2) and data_permuted(31)) or
                        (r2.req.length(1) and data_permuted(15)) or
                        (r2.req.length(0) and data_permuted(7));
        end if;

        -- trim and sign-extend
        for i in 0 to 7 loop
	    if is_X(r2.req.length) then
		trim_ctl(i) := "XX";
            elsif i < to_integer(unsigned(r2.req.length)) then
                if r2.req.dword_index = '1' then
                    trim_ctl(i) := '1' & not r2.use_second(i);
                else
                    trim_ctl(i) := "10";
                end if;
            else
                trim_ctl(i) := "00";
            end if;
        end loop;

        for i in 0 to 7 loop
            case trim_ctl(i) is
                when "11" =>
                    data_trimmed(i * 8 + 7 downto i * 8) := r3.load_data(i * 8 + 7 downto i * 8);
                when "10" =>
                    data_trimmed(i * 8 + 7 downto i * 8) := data_permuted(i * 8 + 7 downto i * 8);
                when others =>
                    data_trimmed(i * 8 + 7 downto i * 8) := (others => negative and r2.req.sign_extend);
            end case;
        end loop;

        if HAS_FPU then
            -- Single-precision FP conversion for loads
            v.ld_sp_data := data_trimmed(31 downto 0);
            v.ld_sp_nz := or (data_trimmed(22 downto 0));
            v.ld_sp_lz := count_left_zeroes(data_trimmed(22 downto 0));
        end if;

        if d_in.valid = '1' and r2.req.load = '1' then
            v.load_data := data_permuted;
        end if;

        hashchk_trap := '0';
        if d_in.valid = '1' and r2.req.hashcmp = '1' then
            if d_in.data = r2.req.store_data then
                v.complete := '1';
            else
                hashchk_trap := '1';
                exception := '1';
            end if;
        end if;

        if r2.req.valid = '1' then
            if r2.req.read_spr = '1' then
                write_enable := '1';
            end if;
            if r2.req.align_intr = '1' then
                -- generate alignment interrupt
                exception := '1';
            end if;
            if r2.req.do_update = '1' then
                do_update := '1';
            end if;
            if r2.req.load_sp = '1' and r2.req.dc_req = '0' then
                write_enable := '1';
            end if;
            if r2.req.write_spr = '1' then
                if r2.req.sprsel(3 downto 2) = "01" then
                    v.dawr_upd := '1';
                end if;
                case r2.req.sprsel is
                    when "0100" =>
                        v.dawr(0) := r2.req.store_data(63 downto 3);
                    when "0101" =>
                        v.dawr(1) := r2.req.store_data(63 downto 3);
                    when "0110" =>
                        v.dawrx(0) := r2.req.store_data(15 downto 0);
                    when "0111" =>
                        v.dawrx(1) := r2.req.store_data(15 downto 0);
                    when "0010" =>
                        v.dsisr := r2.req.store_data(31 downto 0);
                    when "0011" =>
                        v.dar := r2.req.store_data;
                    when others =>
                end case;
            end if;
        end if;

        if r3.state = IDLE and r2.req.valid = '1' and r2.req.mmu_op = '1' then
            -- send request (tlbie, mtspr, itlb miss) to MMU
            mmureq := not r2.req.write_spr;
            mmu_mtspr := r2.req.write_spr;
            if r2.req.instr_fault = '1' then
                v.events.itlb_miss := '1';
            end if;
            v.state := MMU_WAIT;
        end if;

        if d_in.valid = '1' then
            if r2.req.incomplete = '0' then
                write_enable := r2.req.load and not r2.req.load_sp and
                                not r2.req.flush and not r2.req.touch and not r2.req.hashcmp;
                -- stores write back rA update
                do_update := r2.req.update and r2.req.store;
            end if;
        end if;
        if d_in.error = '1' then
            if d_in.cache_paradox = '1' or d_in.reserve_nc = '1' or r2.req.dawr_intr = '1' then
                -- signal an interrupt straight away
                exception := '1';
                dsisr(63 - 41) := r2.req.dawr_intr;
                dsisr(63 - 38) := not r2.req.load;
                dsisr(63 - 37) := d_in.reserve_nc;
                -- XXX there is no architected bit for this
                -- (probably should be a machine check in fact)
                dsisr(63 - 35) := d_in.cache_paradox;
            else
                -- Look up the translation for TLB miss
                -- and also for permission error and RC error
                -- in case the PTE has been updated.
                mmureq := '1';
                v.state := MMU_WAIT;
                v.stage1_en := '0';
            end if;
        end if;

        if m_in.done = '1' then
            if r2.req.dc_req = '1' then
                -- retry the request now that the MMU has installed a TLB entry
                req := '1';
            else
                v.complete := '1';
            end if;
        end if;
        if m_in.err = '1' then
            exception := '1';
            dsisr(63 - 33) := m_in.invalid;
            dsisr(63 - 36) := m_in.perm_error;
            dsisr(63 - 38) := r2.req.store or r2.req.dcbz;
            dsisr(63 - 44) := m_in.badtree;
            dsisr(63 - 45) := m_in.rc_error;
        end if;

        if (m_in.done or m_in.err) = '1' then
            v.stage1_en := '1';
            v.state := IDLE;
        end if;

        v.events.load_complete := r2.req.load and complete;
        v.events.store_complete := (r2.req.store or r2.req.dcbz) and complete;

        -- generate DSI or DSegI for load/store exceptions
        -- or ISI or ISegI for instruction fetch exceptions
        v.interrupt := exception;
        if exception = '1' then
            if r2.req.align_intr = '1' then
                v.intr_vec := 16#600#;
                v.srr1(47 - 34) := r2.req.prefixed;
                v.dar := r2.req.addr;
            elsif hashchk_trap = '1' then
                v.intr_vec := 16#700#;
                v.srr1(47 - 34) := r2.req.prefixed;
                v.srr1(47 - 46) := '1';
            elsif r2.req.instr_fault = '0' then
                v.srr1(47 - 34) := r2.req.prefixed;
                v.dar := r2.req.addr;
                if m_in.segerr = '0' then
                    dsisr(63 - 38) := not r2.req.load;
                    v.intr_vec := 16#300#;
                    v.dsisr := dsisr;
                else
                    v.intr_vec := 16#380#;
                end if;
            else
                if m_in.segerr = '0' then
                    v.srr1(47 - 33) := m_in.invalid;
                    v.srr1(47 - 35) := m_in.perm_error; -- noexec fault
                    v.srr1(47 - 44) := m_in.badtree;
                    v.srr1(47 - 45) := m_in.rc_error;
                    v.intr_vec := 16#400#;
                else
                    v.intr_vec := 16#480#;
                end if;
            end if;
        end if;

        case r2.wr_sel is
        when "00" =>
            -- update reg
            write_data := r2.addr0;
        when "01" =>
            -- lfs result
            write_data := load_dp_data;
        when others =>
            -- load data
            write_data := data_trimmed;
        end case;

        -- Update outputs to dcache
        if r3.stage1_en = '1' then
            d_out.valid <= stage1_dcreq;
            d_out.load <= stage1_req.load;
            d_out.dcbz <= stage1_req.dcbz;
            d_out.flush <= stage1_req.flush;
            d_out.touch <= stage1_req.touch;
            d_out.sync <= stage1_req.sync;
            d_out.nc <= stage1_req.nc;
            d_out.reserve <= stage1_req.reserve;
            d_out.tlb_probe <= stage1_req.tlbie;
            d_out.atomic_qw <= stage1_req.atomic_qw;
            d_out.atomic_first <= stage1_req.atomic_first;
            d_out.atomic_last <= stage1_req.atomic_last;
            d_out.addr <= stage1_req.addr;
            d_out.byte_sel <= stage1_req.byte_sel;
            d_out.virt_mode <= stage1_req.virt_mode;
            d_out.priv_mode <= stage1_req.priv_mode;
        else
            d_out.valid <= req;
            d_out.load <= r2.req.load;
            d_out.dcbz <= r2.req.dcbz;
            d_out.flush <= r2.req.flush;
            d_out.touch <= r2.req.touch;
            d_out.sync <= r2.req.sync;
            d_out.nc <= r2.req.nc;
            d_out.reserve <= r2.req.reserve;
            d_out.tlb_probe <= r2.req.tlbie;
            d_out.atomic_qw <= r2.req.atomic_qw;
            d_out.atomic_first <= r2.req.atomic_first;
            d_out.atomic_last <= r2.req.atomic_last;
            d_out.addr <= r2.req.addr;
            d_out.byte_sel <= r2.req.byte_sel;
            d_out.virt_mode <= r2.req.virt_mode;
            d_out.priv_mode <= r2.req.priv_mode;
        end if;
        if stage1_dreq = '1' then
            d_out.data <= store_data;
            d_out.dawr_match <= stage1_dawr_match;
        else
            d_out.data <= r2.req.store_data;
            d_out.dawr_match <= r2.req.dawr_intr;
        end if;
        d_out.hold <= l_in.e2stall;

        -- Update outputs to MMU
        m_out.valid <= mmureq;
        m_out.iside <= r2.req.instr_fault;
        m_out.load <= r2.req.load;
        m_out.priv <= r2.req.priv_mode;
        m_out.tlbie <= r2.req.tlbie;
        m_out.ric <= r2.req.ric;
        m_out.mtspr <= mmu_mtspr;
        m_out.sprnf <= r1.req.sprsel(0);
        m_out.sprnt <= r2.req.sprsel(0);
        m_out.addr <= r2.req.addr;
        m_out.slbia <= r2.req.is_slbia;
        m_out.rs <= r2.req.store_data;

        -- Update outputs to writeback
        l_out.valid <= complete;
        l_out.instr_tag <= r2.req.instr_tag;
        l_out.write_enable <= write_enable or do_update;
        l_out.write_reg <= r2.req.write_reg;
        l_out.write_data <= write_data;
        l_out.xerc <= r2.req.xerc;
        l_out.rc <= r2.req.rc and complete;
        l_out.store_done <= d_in.store_done;
        l_out.interrupt <= r3.interrupt;
        l_out.intr_vec <= r3.intr_vec;
        l_out.srr1 <= r3.srr1;

        -- update busy signal back to execute1
        e_out.busy <= busy;
        e_out.l2stall <= dc_stall or d_in.error or r2.busy;

        e_out.ea_for_pmu <= req_in.addr;
        e_out.ea_valid <= req_in.ea_valid;

        events <= r3.events;

        flush <= exception;

        -- Update registers
        r3in <= v;

    end process;

    l1_log: if LOG_LENGTH > 0 generate
        signal log_data : std_ulogic_vector(9 downto 0);
    begin
        ls1_log: process(clk)
        begin
            if rising_edge(clk) then
                log_data <= e_out.busy &
                            l_out.interrupt &
                            l_out.valid &
                            m_out.valid &
                            d_out.valid &
                            m_in.done &
                            r2.req.dword_index &
                            r2.req.valid &
                            r2.wait_dc &
                            std_ulogic_vector(to_unsigned(state_t'pos(r3.state), 1));
            end if;
        end process;
        log_out <= log_data;
    end generate;

end;
