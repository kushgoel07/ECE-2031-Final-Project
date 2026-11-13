-- ============================================================================
-- STOPWATCH_PERIPH.vhd
-- ECE 2031 design project baseline: single-stopwatch peripheral for SCOMP
--
-- Features (baseline):
--   * One 16-bit stopwatch: run/pause, reset, resolution (1 ms/10 ms/100 ms/1 s)
--   * Software-triggered laps stored in a lap FIFO
--   * Hardware event capture: an input (e.g. a debounced pushbutton) stamps the
--     current time into an event FIFO, with no CPU involvement
--
-- I/O map (offsets from 0x70; IO_ADDR = low nibble of the I/O address):
--   0x70 CTRL        W/R  bit0 RUN, bit1 RESET (pulse), bits5:4 resolution
--   0x71 TIME        R    current elapsed time
--   0x72 LAP         W    record a lap   | R  pop oldest lap (0 if empty)
--   0x73 STATUS      R    3:0 lap count, 4 full, 5 lap lost, 6 overflow, 7 running
--   0x74 EVT_CTRL    W/R  bit0 enable capture, bit1 clear event FIFO (pulse)
--   0x75 EVT_READ    R    pop oldest event timestamp (0 if empty)
--   0x76 EVT_STATUS  R    4:0 count, 5 full, 6 lost, 7 enabled
--   0x77-0x7F        reserved
--
-- NOTE: baseline, not yet simulated. See the TODO/CHECK comments.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity STOPWATCH_PERIPH is
  generic (
    CLK_HZ      : natural := 50_000_000;  -- frequency of CLK_FAST (CHECK: your clock)
    LAP_DEPTH   : natural := 8;           -- laps stored (power of 2)
    EVT_DEPTH   : natural := 16;          -- event timestamps stored (power of 2)
    DEBOUNCE_MS : natural := 10           -- input must be stable this long
  );
  port (
    CLK_FAST : in    std_logic;                     -- counting clock, much faster than SCOMP's I/O rate
    RESETN   : in    std_logic;
    CS       : in    std_logic;                     -- asserted for any address 0x70-0x7F
    IO_WRITE : in    std_logic;
    IO_ADDR  : in    std_logic_vector(3 downto 0);  -- low nibble of the I/O address
    IO_DATA  : inout std_logic_vector(15 downto 0);
    EVT_IN   : in    std_logic                      -- event input, active high (invert KEY if needed)
  );
end entity STOPWATCH_PERIPH;

architecture rtl of STOPWATCH_PERIPH is

  constant MS_DIV : natural := CLK_HZ / 1000;

  subtype word_t is unsigned(15 downto 0);
  type lap_fifo_t is array (0 to LAP_DEPTH-1) of word_t;
  type evt_fifo_t is array (0 to EVT_DEPTH-1) of word_t;

  -- ---------------- bus side (clocked by CS edges) ----------------
  signal wr_addr  : std_logic_vector(3 downto 0);
  signal wr_data  : std_logic_vector(15 downto 0);
  signal rd_addr  : std_logic_vector(3 downto 0);
  signal is_read  : std_logic;
  signal wr_tog   : std_logic;   -- flips once per write
  signal pop_tog  : std_logic;   -- flips once per FIFO-popping read
  signal pop_addr : std_logic_vector(3 downto 0);
  signal rd_data  : std_logic_vector(15 downto 0);

  -- ---------------- synchronizers into CLK_FAST ----------------
  signal wr_sync  : std_logic_vector(2 downto 0);
  signal pop_sync : std_logic_vector(2 downto 0);
  signal evt_sync : std_logic_vector(1 downto 0);

  -- ---------------- tick generation ----------------
  signal ms_cnt   : natural range 0 to MS_DIV-1;
  signal c10, c100, c1k : natural range 0 to 9;
  signal tick_ms, tick_10, tick_100, tick_1s : std_logic;

  -- ---------------- stopwatch state ----------------
  signal sw_time  : word_t;
  signal sw_run   : std_logic;
  signal sw_res   : std_logic_vector(1 downto 0);
  signal sw_ovf   : std_logic;

  signal lap_mem  : lap_fifo_t;
  signal lap_rd   : natural range 0 to LAP_DEPTH-1;
  signal lap_wr   : natural range 0 to LAP_DEPTH-1;
  signal lap_cnt  : natural range 0 to LAP_DEPTH;
  signal lap_lost : std_logic;

  -- ---------------- event capture ----------------
  signal evt_mem    : evt_fifo_t;
  signal evt_rd     : natural range 0 to EVT_DEPTH-1;
  signal evt_wr     : natural range 0 to EVT_DEPTH-1;
  signal evt_cnt    : natural range 0 to EVT_DEPTH;
  signal evt_lost   : std_logic;
  signal evt_en     : std_logic;
  signal evt_stable : std_logic;
  signal db_cnt     : natural range 0 to DEBOUNCE_MS;

begin

  -- ==========================================================================
  -- 1. BUS INTERFACE
  -- Writes are captured on CS edges, not by sampling CS with a clock (per the
  -- course tip). CHECK: match the edge your course's LEDs.vhd / DIG_OUT uses.
  -- ==========================================================================
  bus_latch : process (RESETN, CS)
  begin
    if RESETN = '0' then
      wr_tog  <= '0';
      wr_addr <= (others => '0');
      wr_data <= (others => '0');
      rd_addr <= (others => '0');
      is_read <= '0';
    elsif rising_edge(CS) then
      if IO_WRITE = '1' then
        wr_addr <= IO_ADDR;
        wr_data <= IO_DATA;
        wr_tog  <= not wr_tog;       -- tell the fast domain "new command"
        is_read <= '0';
      else
        rd_addr <= IO_ADDR;
        is_read <= '1';
      end if;
    end if;
  end process;

  -- A read of a FIFO address pops it at the END of the read (falling edge of
  -- CS), so SCOMP latches the value before the FIFO advances.
  pop_latch : process (RESETN, CS)
  begin
    if RESETN = '0' then
      pop_tog  <= '0';
      pop_addr <= (others => '0');
    elsif falling_edge(CS) then
      if is_read = '1' and (rd_addr = x"2" or rd_addr = x"5") then
        pop_addr <= rd_addr;
        pop_tog  <= not pop_tog;
      end if;
    end if;
  end process;

  -- ==========================================================================
  -- 2. TICK GENERATION: 1 ms base tick, then /10 cascades
  -- Each tick_* is a single CLK_FAST-cycle pulse.
  -- ==========================================================================
  tick_ms  <= '1'      when ms_cnt = MS_DIV-1 else '0';
  tick_10  <= tick_ms  when c10  = 9 else '0';
  tick_100 <= tick_10  when c100 = 9 else '0';
  tick_1s  <= tick_100 when c1k  = 9 else '0';

  -- ==========================================================================
  -- 3. MAIN LOGIC (CLK_FAST domain)
  -- Order matters: later assignments in this process win, so commands
  -- (reset, clear) come last and override counting.
  -- ==========================================================================
  main : process (RESETN, CLK_FAST)
    variable wr_ev, pop_ev : boolean;
    variable evt_push      : boolean;
    variable ecnt          : natural range 0 to EVT_DEPTH;
    variable tick          : std_logic;
  begin
    if RESETN = '0' then
      wr_sync    <= (others => '0');
      pop_sync   <= (others => '0');
      evt_sync   <= (others => '0');
      ms_cnt     <= 0;
      c10        <= 0;
      c100       <= 0;
      c1k        <= 0;
      sw_time    <= (others => '0');
      sw_run     <= '0';
      sw_res     <= "00";
      sw_ovf     <= '0';
      lap_rd     <= 0;
      lap_wr     <= 0;
      lap_cnt    <= 0;
      lap_lost   <= '0';
      evt_rd     <= 0;
      evt_wr     <= 0;
      evt_cnt    <= 0;
      evt_lost   <= '0';
      evt_en     <= '0';
      evt_stable <= '0';
      db_cnt     <= 0;

    elsif rising_edge(CLK_FAST) then

      -- ---- synchronize bus toggles and the event input ----
      wr_sync  <= wr_sync(1 downto 0)  & wr_tog;
      pop_sync <= pop_sync(1 downto 0) & pop_tog;
      evt_sync <= evt_sync(0) & EVT_IN;
      wr_ev    := (wr_sync(2)  /= wr_sync(1));    -- a toggle changed = new request
      pop_ev   := (pop_sync(2) /= pop_sync(1));
      evt_push := false;

      -- ---- tick dividers ----
      if ms_cnt = MS_DIV-1 then ms_cnt <= 0; else ms_cnt <= ms_cnt + 1; end if;
      if tick_ms  = '1' then if c10  = 9 then c10  <= 0; else c10  <= c10  + 1; end if; end if;
      if tick_10  = '1' then if c100 = 9 then c100 <= 0; else c100 <= c100 + 1; end if; end if;
      if tick_100 = '1' then if c1k  = 9 then c1k  <= 0; else c1k  <= c1k  + 1; end if; end if;

      -- ---- count at the selected resolution ----
      case sw_res is
        when "00"   => tick := tick_ms;
        when "01"   => tick := tick_10;
        when "10"   => tick := tick_100;
        when others => tick := tick_1s;
      end case;
      if sw_run = '1' and tick = '1' then
        if sw_time = x"FFFF" then
          sw_ovf <= '1';                         -- wrapped around
        end if;
        sw_time <= sw_time + 1;
      end if;

      -- ---- debounce the event input; a clean rising edge = one event ----
      if evt_sync(1) /= evt_stable then
        if tick_ms = '1' then
          if db_cnt = DEBOUNCE_MS-1 then
            evt_stable <= evt_sync(1);
            db_cnt     <= 0;
            if evt_sync(1) = '1' then
              evt_push := true;
            end if;
          else
            db_cnt <= db_cnt + 1;
          end if;
        end if;
      else
        db_cnt <= 0;
      end if;

      -- ---- event FIFO: pop (from a read) and push (from hardware) ----
      -- Both can happen in the same cycle, so the count is a variable.
      ecnt := evt_cnt;
      if pop_ev and pop_addr = x"5" and ecnt > 0 then
        evt_rd <= (evt_rd + 1) mod EVT_DEPTH;
        ecnt   := ecnt - 1;
      end if;
      if evt_push and evt_en = '1' then
        if ecnt < EVT_DEPTH then
          evt_mem(evt_wr) <= sw_time;            -- timestamp, no CPU involved
          evt_wr <= (evt_wr + 1) mod EVT_DEPTH;
          ecnt   := ecnt + 1;
        else
          evt_lost <= '1';                       -- full: drop newest
        end if;
      end if;
      evt_cnt <= ecnt;

      -- ---- lap FIFO pop (read of 0x72) ----
      -- Lap pushes and pops both come from SCOMP instructions, so they never
      -- land in the same cycle.
      if pop_ev and pop_addr = x"2" and lap_cnt > 0 then
        lap_rd  <= (lap_rd + 1) mod LAP_DEPTH;
        lap_cnt <= lap_cnt - 1;
      end if;

      -- ---- commands from SCOMP writes ----
      if wr_ev then
        case wr_addr is

          when x"0" =>                                   -- CTRL
            sw_run <= wr_data(0);
            sw_res <= wr_data(5 downto 4);
            if wr_data(1) = '1' then
              sw_time  <= (others => '0');
              sw_ovf   <= '0';
              lap_rd   <= 0;
              lap_wr   <= 0;
              lap_cnt  <= 0;
              lap_lost <= '0';
            end if;

          when x"2" =>                                   -- LAP: record a lap
            if lap_cnt < LAP_DEPTH then
              lap_mem(lap_wr) <= sw_time;
              lap_wr  <= (lap_wr + 1) mod LAP_DEPTH;
              lap_cnt <= lap_cnt + 1;
            else
              lap_lost <= '1';                           -- full: drop newest
            end if;

          when x"4" =>                                   -- EVT_CTRL
            evt_en <= wr_data(0);
            if wr_data(1) = '1' then
              evt_rd   <= 0;
              evt_wr   <= 0;
              evt_cnt  <= 0;
              evt_lost <= '0';
            end if;

          when others =>
            null;                                        -- reserved / read-only
        end case;
      end if;

    end if;
  end process;

  -- ==========================================================================
  -- 4. READ MUX (combinational) + tri-state onto IO_DATA
  -- TODO: TIME can change mid-read; consider latching it (snapshot read).
  -- ==========================================================================
  read_mux : process (IO_ADDR, sw_run, sw_res, sw_time, sw_ovf,
                      lap_mem, lap_rd, lap_cnt, lap_lost,
                      evt_mem, evt_rd, evt_cnt, evt_lost, evt_en)
  begin
    rd_data <= (others => '0');
    case IO_ADDR is
      when x"0" =>
        rd_data(0)          <= sw_run;
        rd_data(5 downto 4) <= sw_res;
      when x"1" =>
        rd_data <= std_logic_vector(sw_time);
      when x"2" =>
        if lap_cnt > 0 then
          rd_data <= std_logic_vector(lap_mem(lap_rd));
        end if;
      when x"3" =>
        rd_data(3 downto 0) <= std_logic_vector(to_unsigned(lap_cnt, 4));
        if lap_cnt = LAP_DEPTH then rd_data(4) <= '1'; end if;
        rd_data(5) <= lap_lost;
        rd_data(6) <= sw_ovf;
        rd_data(7) <= sw_run;
      when x"4" =>
        rd_data(0) <= evt_en;
      when x"5" =>
        if evt_cnt > 0 then
          rd_data <= std_logic_vector(evt_mem(evt_rd));
        end if;
      when x"6" =>
        rd_data(4 downto 0) <= std_logic_vector(to_unsigned(evt_cnt, 5));
        if evt_cnt = EVT_DEPTH then rd_data(5) <= '1'; end if;
        rd_data(6) <= evt_lost;
        rd_data(7) <= evt_en;
      when others =>
        null;
    end case;
  end process;

  -- Drive the bus only during a read of this peripheral.
  -- CHECK: the course template may use LPM_BUSTRI instead; either works.
  IO_DATA <= rd_data when (CS = '1' and IO_WRITE = '0') else (others => 'Z');

end architecture rtl;
