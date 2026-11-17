-- STOPWATCH_PERIPH.vhd
-- ECE 2031 Final Project
-- Stopwatch peripheral for SCOMP (uses I/O addresses 0x70-0x7F)
--
-- What it does right now:
--   - one 16-bit stopwatch with run/pause/reset
--   - 4 resolutions: 1 ms, 10 ms, 100 ms, 1 s
--   - laps get saved in a queue (8 deep) so the program can read them later
--   - button presses get timestamped in hardware into a second queue (16 deep)

LIBRARY IEEE;
LIBRARY LPM;

USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.NUMERIC_STD.ALL;
USE LPM.LPM_COMPONENTS.ALL;


ENTITY STOPWATCH_PERIPH IS
  PORT(
    CLOCK    : IN    STD_LOGIC;                      -- fast clock (50 MHz), used for counting
    RESETN   : IN    STD_LOGIC;
    CS       : IN    STD_LOGIC;                      -- high for any address 0x70-0x7F
    IO_WRITE : IN    STD_LOGIC;
    IO_ADDR  : IN    STD_LOGIC_VECTOR(3 DOWNTO 0);   -- low 4 bits of the address
    IO_DATA  : INOUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    BTN      : IN    STD_LOGIC                       -- button for event capture (active high)
  );
END STOPWATCH_PERIPH;


ARCHITECTURE a OF STOPWATCH_PERIPH IS

  -- 50 MHz / 50,000 = 1 kHz, so this gives us a 1 ms tick
  -- change this if we use a different clock
  CONSTANT MS_COUNT : INTEGER := 50000;

  TYPE LAP_ARRAY IS ARRAY (0 TO 7)  OF UNSIGNED(15 DOWNTO 0);
  TYPE EVT_ARRAY IS ARRAY (0 TO 15) OF UNSIGNED(15 DOWNTO 0);

  -- stuff latched from SCOMP writes/reads
  SIGNAL wr_addr  : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL wr_data  : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL rd_addr  : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL is_read  : STD_LOGIC;
  SIGNAL pop_addr : STD_LOGIC_VECTOR(3 DOWNTO 0);
  SIGNAL wr_flag  : STD_LOGIC;   -- flips every time SCOMP writes to us
  SIGNAL pop_flag : STD_LOGIC;   -- flips every time SCOMP reads a FIFO
  SIGNAL rd_data  : STD_LOGIC_VECTOR(15 DOWNTO 0);
  SIGNAL out_en   : STD_LOGIC;

  -- syncing the flags + button into the CLOCK side
  SIGNAL wr_sync  : STD_LOGIC_VECTOR(2 DOWNTO 0);
  SIGNAL pop_sync : STD_LOGIC_VECTOR(2 DOWNTO 0);
  SIGNAL btn_sync : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL new_wr   : STD_LOGIC;
  SIGNAL new_pop  : STD_LOGIC;

  -- tick counters
  SIGNAL ms_cnt   : UNSIGNED(15 DOWNTO 0);
  SIGNAL cnt10    : UNSIGNED(3 DOWNTO 0);
  SIGNAL cnt100   : UNSIGNED(3 DOWNTO 0);
  SIGNAL cnt1s    : UNSIGNED(3 DOWNTO 0);
  SIGNAL tick_1ms   : STD_LOGIC;
  SIGNAL tick_10ms  : STD_LOGIC;
  SIGNAL tick_100ms : STD_LOGIC;
  SIGNAL tick_1s    : STD_LOGIC;
  SIGNAL tick       : STD_LOGIC;   -- whichever tick matches the resolution

  -- stopwatch
  SIGNAL sw_time  : UNSIGNED(15 DOWNTO 0);
  SIGNAL sw_run   : STD_LOGIC;
  SIGNAL sw_res   : STD_LOGIC_VECTOR(1 DOWNTO 0);
  SIGNAL sw_ovf   : STD_LOGIC;

  -- lap FIFO (3-bit pointers wrap around at 8 on their own)
  SIGNAL lap_mem  : LAP_ARRAY;
  SIGNAL lap_rd   : UNSIGNED(2 DOWNTO 0);
  SIGNAL lap_wr   : UNSIGNED(2 DOWNTO 0);
  SIGNAL lap_cnt  : UNSIGNED(3 DOWNTO 0);
  SIGNAL lap_lost : STD_LOGIC;

  -- event FIFO (4-bit pointers wrap around at 16)
  SIGNAL evt_mem  : EVT_ARRAY;
  SIGNAL evt_rd   : UNSIGNED(3 DOWNTO 0);
  SIGNAL evt_wr   : UNSIGNED(3 DOWNTO 0);
  SIGNAL evt_cnt  : UNSIGNED(4 DOWNTO 0);
  SIGNAL evt_lost : STD_LOGIC;
  SIGNAL evt_en   : STD_LOGIC;
  SIGNAL btn_prev : STD_LOGIC;
  SIGNAL evt_push : STD_LOGIC;
  SIGNAL evt_pop  : STD_LOGIC;
  SIGNAL evt_ok   : STD_LOGIC;   -- push is allowed (not full, or popping at the same time)

BEGIN

  -- ---------------------------------------------------------------
  -- SCOMP side
  -- prof said not to sample CS with a clock, so we grab writes on the
  -- rising edge of CS instead (same idea as LEDs.vhd)
  -- ---------------------------------------------------------------
  PROCESS (RESETN, CS)
  BEGIN
    IF (RESETN = '0') THEN
      wr_flag <= '0';
      wr_addr <= "0000";
      wr_data <= x"0000";
      rd_addr <= "0000";
      is_read <= '0';
    ELSIF RISING_EDGE(CS) THEN
      IF (IO_WRITE = '1') THEN
        wr_addr <= IO_ADDR;
        wr_data <= IO_DATA;
        wr_flag <= NOT wr_flag;    -- tells the clock side there's a new command
        is_read <= '0';
      ELSE
        rd_addr <= IO_ADDR;
        is_read <= '1';
      END IF;
    END IF;
  END PROCESS;

  -- reading a FIFO should remove the item, but only AFTER SCOMP has
  -- grabbed the value, so we do it on the falling edge of CS
  PROCESS (RESETN, CS)
  BEGIN
    IF (RESETN = '0') THEN
      pop_flag <= '0';
      pop_addr <= "0000";
    ELSIF FALLING_EDGE(CS) THEN
      IF (is_read = '1') AND (rd_addr = "0010" OR rd_addr = "0101") THEN
        pop_addr <= rd_addr;
        pop_flag <= NOT pop_flag;
      END IF;
    END IF;
  END PROCESS;

  -- a flag changing value = SCOMP did something we need to handle
  new_wr  <= wr_sync(2)  XOR wr_sync(1);
  new_pop <= pop_sync(2) XOR pop_sync(1);


  -- ---------------------------------------------------------------
  -- ticks: 1 ms from the clock, then divide by 10 three times
  -- each tick is high for only one clock cycle
  -- ---------------------------------------------------------------
  tick_1ms   <= '1'        WHEN ms_cnt = MS_COUNT - 1 ELSE '0';
  tick_10ms  <= tick_1ms   WHEN cnt10  = 9 ELSE '0';
  tick_100ms <= tick_10ms  WHEN cnt100 = 9 ELSE '0';
  tick_1s    <= tick_100ms WHEN cnt1s  = 9 ELSE '0';

  WITH sw_res SELECT tick <=
    tick_1ms   WHEN "00",
    tick_10ms  WHEN "01",
    tick_100ms WHEN "10",
    tick_1s    WHEN OTHERS;


  -- ---------------------------------------------------------------
  -- event FIFO control
  -- button is sampled every 10 ms, which also debounces it
  -- (a press only counts when it goes from 0 to 1 between samples)
  -- ---------------------------------------------------------------
  evt_push <= '1' WHEN (tick_10ms = '1' AND btn_sync(1) = '1' AND btn_prev = '0'
                        AND evt_en = '1') ELSE '0';
  evt_pop  <= '1' WHEN (new_pop = '1' AND pop_addr = "0101" AND evt_cnt /= 0) ELSE '0';
  evt_ok   <= '1' WHEN (evt_push = '1' AND (evt_cnt /= 16 OR evt_pop = '1')) ELSE '0';


  -- ---------------------------------------------------------------
  -- main logic (everything on CLOCK)
  -- commands are at the bottom on purpose: last assignment wins in a
  -- process, so a reset always beats a count in the same cycle
  -- ---------------------------------------------------------------
  PROCESS (RESETN, CLOCK)
  BEGIN
    IF (RESETN = '0') THEN
      wr_sync  <= "000";
      pop_sync <= "000";
      btn_sync <= "00";
      ms_cnt   <= (OTHERS => '0');
      cnt10    <= "0000";
      cnt100   <= "0000";
      cnt1s    <= "0000";
      sw_time  <= x"0000";
      sw_run   <= '0';
      sw_res   <= "00";
      sw_ovf   <= '0';
      lap_rd   <= "000";
      lap_wr   <= "000";
      lap_cnt  <= "0000";
      lap_lost <= '0';
      evt_rd   <= "0000";
      evt_wr   <= "0000";
      evt_cnt  <= "00000";
      evt_lost <= '0';
      evt_en   <= '0';
      btn_prev <= '0';

    ELSIF RISING_EDGE(CLOCK) THEN

      -- 2 flip flops so we don't get metastability from the other side
      wr_sync  <= wr_sync(1 DOWNTO 0)  & wr_flag;
      pop_sync <= pop_sync(1 DOWNTO 0) & pop_flag;
      btn_sync <= btn_sync(0) & BTN;

      -- tick counters
      IF (ms_cnt = MS_COUNT - 1) THEN
        ms_cnt <= (OTHERS => '0');
      ELSE
        ms_cnt <= ms_cnt + 1;
      END IF;

      IF (tick_1ms = '1') THEN
        IF (cnt10 = 9) THEN cnt10 <= "0000"; ELSE cnt10 <= cnt10 + 1; END IF;
      END IF;
      IF (tick_10ms = '1') THEN
        IF (cnt100 = 9) THEN cnt100 <= "0000"; ELSE cnt100 <= cnt100 + 1; END IF;
      END IF;
      IF (tick_100ms = '1') THEN
        IF (cnt1s = 9) THEN cnt1s <= "0000"; ELSE cnt1s <= cnt1s + 1; END IF;
      END IF;

      -- count up if running
      IF (sw_run = '1' AND tick = '1') THEN
        IF (sw_time = x"FFFF") THEN
          sw_ovf <= '1';           -- about to wrap back to 0
        END IF;
        sw_time <= sw_time + 1;
      END IF;

      -- button sampling for the debounce
      IF (tick_10ms = '1') THEN
        btn_prev <= btn_sync(1);
      END IF;

      -- event FIFO
      IF (evt_pop = '1') THEN
        evt_rd <= evt_rd + 1;
      END IF;
      IF (evt_ok = '1') THEN
        evt_mem(TO_INTEGER(evt_wr)) <= sw_time;   -- save the timestamp
        evt_wr <= evt_wr + 1;
      END IF;
      IF (evt_push = '1' AND evt_ok = '0') THEN
        evt_lost <= '1';           -- FIFO was full, press got dropped
      END IF;
      IF (evt_ok = '1' AND evt_pop = '0') THEN
        evt_cnt <= evt_cnt + 1;
      ELSIF (evt_pop = '1' AND evt_ok = '0') THEN
        evt_cnt <= evt_cnt - 1;
      END IF;

      -- lap FIFO pop (SCOMP read 0x72)
      IF (new_pop = '1' AND pop_addr = "0010" AND lap_cnt /= 0) THEN
        lap_rd  <= lap_rd + 1;
        lap_cnt <= lap_cnt - 1;
      END IF;

      -- commands from SCOMP
      IF (new_wr = '1') THEN
        CASE wr_addr IS

          WHEN "0000" =>           -- 0x70 CTRL
            sw_run <= wr_data(0);
            sw_res <= wr_data(5 DOWNTO 4);
            IF (wr_data(1) = '1') THEN
              sw_time  <= x"0000";
              sw_ovf   <= '0';
              lap_rd   <= "000";
              lap_wr   <= "000";
              lap_cnt  <= "0000";
              lap_lost <= '0';
            END IF;

          WHEN "0010" =>           -- 0x72 record a lap
            IF (lap_cnt /= 8) THEN
              lap_mem(TO_INTEGER(lap_wr)) <= sw_time;
              lap_wr  <= lap_wr + 1;
              lap_cnt <= lap_cnt + 1;
            ELSE
              lap_lost <= '1';     -- full, lap gets dropped
            END IF;

          WHEN "0100" =>           -- 0x74 EVT_CTRL
            evt_en <= wr_data(0);
            IF (wr_data(1) = '1') THEN
              evt_rd   <= "0000";
              evt_wr   <= "0000";
              evt_cnt  <= "00000";
              evt_lost <= '0';
            END IF;

          WHEN OTHERS =>
            NULL;

        END CASE;
      END IF;

    END IF;
  END PROCESS;


  -- ---------------------------------------------------------------
  -- what SCOMP sees when it reads each address
  -- TODO: sw_time could change in the middle of a read, maybe latch it
  -- ---------------------------------------------------------------
  PROCESS (IO_ADDR, sw_run, sw_res, sw_time, sw_ovf, lap_mem, lap_rd, lap_cnt,
           lap_lost, evt_mem, evt_rd, evt_cnt, evt_lost, evt_en)
  BEGIN
    rd_data <= x"0000";
    CASE IO_ADDR IS

      WHEN "0000" =>               -- 0x70 CTRL
        rd_data(0)          <= sw_run;
        rd_data(5 DOWNTO 4) <= sw_res;

      WHEN "0001" =>               -- 0x71 TIME
        rd_data <= STD_LOGIC_VECTOR(sw_time);

      WHEN "0010" =>               -- 0x72 oldest lap (0 if empty)
        IF (lap_cnt /= 0) THEN
          rd_data <= STD_LOGIC_VECTOR(lap_mem(TO_INTEGER(lap_rd)));
        END IF;

      WHEN "0011" =>               -- 0x73 STATUS
        rd_data(3 DOWNTO 0) <= STD_LOGIC_VECTOR(lap_cnt);
        IF (lap_cnt = 8) THEN
          rd_data(4) <= '1';
        END IF;
        rd_data(5) <= lap_lost;
        rd_data(6) <= sw_ovf;
        rd_data(7) <= sw_run;

      WHEN "0100" =>               -- 0x74 EVT_CTRL
        rd_data(0) <= evt_en;

      WHEN "0101" =>               -- 0x75 oldest event (0 if empty)
        IF (evt_cnt /= 0) THEN
          rd_data <= STD_LOGIC_VECTOR(evt_mem(TO_INTEGER(evt_rd)));
        END IF;

      WHEN "0110" =>               -- 0x76 EVT_STATUS
        rd_data(4 DOWNTO 0) <= STD_LOGIC_VECTOR(evt_cnt);
        IF (evt_cnt = 16) THEN
          rd_data(5) <= '1';
        END IF;
        rd_data(6) <= evt_lost;
        rd_data(7) <= evt_en;

      WHEN OTHERS =>
        NULL;

    END CASE;
  END PROCESS;

  -- only drive the bus when SCOMP is reading from us
  out_en <= CS AND NOT IO_WRITE;

  IO_BUS : LPM_BUSTRI
  GENERIC MAP (
    lpm_width => 16
  )
  PORT MAP (
    data     => rd_data,
    enabledt => out_en,
    tridata  => IO_DATA
  );

END a;
