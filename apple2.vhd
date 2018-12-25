-------------------------------------------------------------------------------
--
-- Top level of an Apple ][+
--
-- Stephen A. Edwards, sedwards@cs.columbia.edu
--
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity apple2 is
  port (
    CLK_14M        : in  std_logic;              -- 14.31818 MHz master clock
    CLK_2M         : out std_logic;
    PRE_PHASE_ZERO : out std_logic;
    FLASH_CLK      : in  std_logic;        -- approx. 2 Hz flashing char clock
    reset          : in  std_logic;
    cpu            : in  std_logic;              -- 0 - 6502, 1 - 65C02
    ADDR           : out unsigned(15 downto 0);  -- CPU address
    ram_addr       : out unsigned(17 downto 0);  -- RAM address
    D              : out unsigned(7 downto 0);   -- Data to RAM
    ram_do         : in unsigned(7 downto 0);    -- Data from RAM
    PD             : in unsigned(7 downto 0);    -- Data to CPU from peripherals
    ram_we         : out std_logic;              -- RAM write enable
    VIDEO          : out std_logic;
    COLOR_LINE     : out std_logic;
    HBL            : out std_logic;
    VBL            : out std_logic;
    K              : in unsigned(7 downto 0);    -- Keyboard data
    READ_KEY       : out std_logic;              -- Processor has read key
    AN             : out std_logic_vector(3 downto 0);  -- Annunciator outputs
    -- GAMEPORT input bits:
    --  7    6    5    4    3   2   1    0
    -- pdl3 pdl2 pdl1 pdl0 pb3 pb2 pb1 casette
    GAMEPORT       : in std_logic_vector(7 downto 0);
    PDL_STROBE     : out std_logic;         -- Pulses high when C07x read
    STB            : out std_logic;         -- Pulses high when C04x read
    IO_SELECT      : out std_logic_vector(7 downto 0);
    DEVICE_SELECT  : out std_logic_vector(7 downto 0);
    pcDebugOut     : out unsigned(15 downto 0);
    opcodeDebugOut : out unsigned(7 downto 0);
    laudio         : out std_logic;
    raudio         : out std_logic;
    mb_enabled     : in std_logic;
    speaker        : out std_logic              -- One-bit speaker output
    );
end apple2;

architecture rtl of apple2 is

  component ramcard is
    port ( mclk28: in std_logic;
           reset_in: in std_logic;
           PAGE2, HIRES, RAMRD, RAMWRT, STORE80, ALTZP: in std_logic;
           addr: in std_logic_vector(15 downto 0);
           video_addr: in std_logic_vector(15 downto 0);
           ram_addr: out std_logic_vector(17 downto 0);
           video_ram_addr: out std_logic_vector(17 downto 0);
           we: in std_logic;  
           card_ram_we: out std_logic;
           card_ram_rd: out std_logic;
           bank1: out std_logic
    );
  end component;
  
  -- Clocks
  signal CLK_7M : std_logic;
  signal Q3, RAS_N, CAS_N, AX : std_logic;
  signal PHASE_ZERO, PHASE_ZERO_D, PRE_PHASE_ZERO_sig : std_logic;
  signal COLOR_REF : std_logic;
  signal CPU_EN, CPU_EN_POST : std_logic;

  -- From the timing generator
  signal VIDEO_ADDRESS : unsigned(15 downto 0);
  signal LDPS_N : std_logic;
  signal H0 : std_logic;
  signal VBL_REG, BLANK, GR2 : std_logic;
  signal SEGA, SEGB, SEGC : std_logic;

  signal HIRES : std_logic;             -- from video generator B11 p6
  signal DHIRES : std_logic;
  
  -- Soft switches
  signal soft_switches : std_logic_vector(7 downto 0) := "00000000";
  signal TEXT_MODE : std_logic;
  signal MIXED_MODE : std_logic;
  signal PAGE2 : std_logic;
  signal HIRES_MODE : std_logic;
  signal DHIRES_MODE : std_logic;

  -- ][e auxilary switches
  signal RAMRD : std_logic;
  signal RAMWRT : std_logic;
  signal CXROM : std_logic;
  signal STORE80 : std_logic;
  signal C3ROM : std_logic;
  signal ALTZP : std_logic;
  signal ALTCHAR : std_logic;
  signal COL80 : std_logic;
  signal IOUDIS : std_logic;
  signal SF_D : std_logic;

  -- CPU signals
  signal D_IN : unsigned(7 downto 0);
  signal D_OUT: unsigned(7 downto 0);
  signal A : unsigned(15 downto 0);
  signal T65_A : std_logic_vector(23 downto 0);
  signal T65_DI : std_logic_vector(7 downto 0);
  signal T65_DO : std_logic_vector(7 downto 0);
  signal T65_WE_N : std_logic;
  signal R65C02_A : unsigned(15 downto 0);
  signal R65C02_DO : unsigned(7 downto 0);
  signal R65C02_WE_N : std_logic;
  signal we : std_logic;

  -- Main ROM signals
  signal rom_out : unsigned(7 downto 0);
  signal rom_addr : unsigned(13 downto 0);

  -- Address decoder signals
  signal RAM_SELECT : std_logic := '1';
  signal KEYBOARD_SELECT : std_logic := '0';
  signal SPEAKER_SELECT : std_logic;
  signal SOFTSWITCH_SELECT : std_logic;
  signal SOFTSWITCH_RD_SELECT : std_logic;
  signal ROM_SELECT : std_logic;
  signal GAMEPORT_SELECT : std_logic;
  signal IO_STROBE : std_logic;
  signal PDL_STROBE_REG : std_logic;

  -- Speaker signal
  signal speaker_sig : std_logic := '0';        

  signal CPU_DL, VIDEO_DL : unsigned(7 downto 0);     -- Latched RAM data
  
  -- ramcard
  signal card_addr : unsigned(17 downto 0);
  signal card_video_addr: unsigned(17 downto 0);
  signal card_ram_rd : std_logic;
  signal card_ram_we : std_logic;
  signal ram_card_read : std_logic;
  signal ram_card_write : std_logic;

  signal psg_irq_n : std_logic;
  signal psg_do    : unsigned(7 downto 0);
  
  signal ioselect  : std_logic_vector(7 downto 0);
  signal devselect : std_logic_vector(7 downto 0);
  
  signal R_W_n     : std_logic;

begin

  CLK_2M <= Q3;
  PRE_PHASE_ZERO <= PRE_PHASE_ZERO_sig;

  ram_addr <= card_addr when PHASE_ZERO = '1' else card_video_addr;
  ram_we <= ((we and RAM_SELECT) or (we and ram_card_write)) when PHASE_ZERO = '1' else '0';

  -- Latch RAM data on the rising edge of RAS
  RAM_data_latch : process (CLK_14M)
  begin
    if rising_edge(CLK_14M) then
--      if AX = '1' and CAS_N = '0' and RAS_N = '0' then
      if AX = '0' and CAS_N = '0' and RAS_N = '0' and Q3 = '1' then
        if PHASE_ZERO = '0' then
            VIDEO_DL <= ram_do;
        else
            CPU_DL <= ram_do;
        end if;
      end if;
    end if;
  end process;

  ADDR <= A;
  D <= D_OUT;

  IO_SELECT <= ioselect;
  DEVICE_SELECT <= devselect;
  PDL_STROBE <= PDL_STROBE_REG;

  -- Address decoding
--  rom_addr <= (A(13) and A(12)) & (not A(12)) & A(11 downto 0);
  rom_addr <= A(13 downto 0);

  address_decoder: process (A, C3ROM, CXROM)
  begin
    ROM_SELECT <= '0';
    RAM_SELECT <= '0';
    KEYBOARD_SELECT <= '0';
    READ_KEY <= '0';
    SPEAKER_SELECT <= '0';
    SOFTSWITCH_SELECT <= '0';
    SOFTSWITCH_RD_SELECT <= '0';
    GAMEPORT_SELECT <= '0';
    PDL_STROBE_REG <= '0';
    STB <= '0';
    ioselect <= (others => '0');
    devselect <= (others => '0');
    IO_STROBE <= '0';
    case A(15 downto 14) is
      when "00" | "01" | "10" =>         -- 0000 - BFFF
        RAM_SELECT <= '1';
      when "11" => -- C000 - FFFF
        case A(13 downto 12) is
          when "00" =>                  -- C000 - CFFF
            case A(11 downto 8) is
              when x"0" =>              -- C000 - C0FF
                case A(7 downto 4) is
                  when x"0" =>          -- C000 - C00F
                     KEYBOARD_SELECT <= '1';
                  when x"1" =>          -- C010 - C01F
                     case A(3 downto 0) is
                        when x"0" | x"1" | x"2" =>
                           READ_KEY <= '1';
                        when others =>
                           SOFTSWITCH_RD_SELECT <= '1';
                     end case;
                  when x"3" =>          -- C030 - C03F
                    SPEAKER_SELECT <= '1';
                  when x"4" =>
                    STB <= '1';
                  when x"5" =>          -- C050 - C05F
                    SOFTSWITCH_SELECT <= '1';
                  when x"6" =>          -- C060 - C06F
                    GAMEPORT_SELECT <= '1';
                  when x"7" =>          -- C070 - C07F
                    PDL_STROBE_REG <= '1';
                  when x"8" | x"9" | x"A" |  -- C080 - C0FF
                       x"B" | x"C" | x"D" | x"E" | x"F" =>
                    devselect(TO_INTEGER(A(6 downto 4))) <= '1';
                  when others => null;                
                end case;
              when x"1" | x"2" |   -- C100 - C2FF, C400-C7FF
                   x"4" | x"5" | x"6" | x"7" =>
                if CXROM = '1' then
                  ROM_SELECT <= '1';
                else
                  ioselect(TO_INTEGER(A(10 downto 8))) <= '1';
                end if;
              when x"3" => -- C300 - C3FF
                if CXROM = '1' or C3ROM = '0' then
                  ROM_SELECT <= '1';
                else
                  ioselect(TO_INTEGER(A(10 downto 8))) <= '1';
                end if;
              when x"8" | x"9" | x"A" |  -- C800 - CFFF
                   x"B" | x"C" | x"D" | x"E" | x"F" =>
                if CXROM = '1' then
                  ROM_SELECT <= '1';
                else
                  IO_STROBE <= '1';
                end if;
              when others => null;
            end case;
          when "01" | "10" | "11" =>    -- D000 - FFFF
            ROM_SELECT <= '1';
          when others =>
            null;
        end case;
      when others => null;
    end case;        
  end process address_decoder;

  speaker_ctrl: process (CLK_14M)
  begin
    if rising_edge(CLK_14M) then
      if CPU_EN_POST = '1' and SPEAKER_SELECT = '1' then
        speaker_sig <= not speaker_sig;
      end if;
    end if;
  end process speaker_ctrl;

  softswitches: process (CLK_14M)
  begin
    if rising_edge(CLK_14M) then
      if SOFTSWITCH_SELECT = '1' then
        soft_switches(TO_INTEGER(A(3 downto 1))) <= A(0);
        if IOUDIS = '0' and A(3 downto 1) = "111" then DHIRES_MODE <= A(0); end if;
      end if;
    end if;
  end process softswitches;

  TEXT_MODE <= soft_switches(0);
  MIXED_MODE <= soft_switches(1);
  PAGE2 <= soft_switches(2);
  HIRES_MODE <= soft_switches(3);
  AN <= soft_switches(7 downto 4);

  softswitches_IIe: process (CLK_14M, reset)
  begin
    if reset = '1' then
      STORE80 <= '0';
      RAMRD <= '0';
      RAMWRT <= '0';
      CXROM <= '0';
      ALTZP <= '0';
      C3ROM <= '0';
      COL80 <= '0';
      ALTCHAR <= '0';
    elsif rising_edge(CLK_14M) then
      if CPU_EN_POST = '1' and KEYBOARD_SELECT = '1' and we = '1' then
        case A(3 downto 1) is
        when "000" => STORE80 <= A(0);
        when "001" => RAMRD <= A(0);
        when "010" => RAMWRT <= A(0);
        when "011" => CXROM <= A(0);
        when "100" => ALTZP <= A(0);
        when "101" => C3ROM <= A(0);
        when "110" => COL80 <= A(0);
        when "111" => ALTCHAR <= A(0);
        when others => null;
        end case;
      elsif CPU_EN_POST = '1' and PDL_STROBE_REG = '1' and we = '1' then
        if A(3 downto 1) = "111" then IOUDIS <= A(0); end if;
      elsif SOFTSWITCH_RD_SELECT = '1' and we = '0' then
        case A(3 downto 0) is
        when x"3" => SF_D <= RAMRD;
        when x"4" => SF_D <= RAMWRT;
        when x"5" => SF_D <= CXROM;
        when x"6" => SF_D <= ALTZP;
        when x"7" => SF_D <= C3ROM;
        when x"8" => SF_D <= STORE80;
        when x"9" => SF_D <= not VBL_REG;
        when x"A" => SF_D <= TEXT_MODE;
        when x"B" => SF_D <= MIXED_MODE;
        when x"C" => SF_D <= PAGE2;
        when x"D" => SF_D <= HIRES_MODE;
        when x"E" => SF_D <= ALTCHAR;
        when x"F" => SF_D <= COL80;
        when others => null;
        end case;
      end if;
    end if;
  end process softswitches_IIe;

  speaker <= speaker_sig;

  D_IN <= CPU_DL when RAM_SELECT = '1' or ram_card_read = '1' else  -- RAM
          K when KEYBOARD_SELECT = '1' else  -- Keyboard
          SF_D & "0000000" when SOFTSWITCH_RD_SELECT = '1' else -- ][e softswitches
          GAMEPORT(TO_INTEGER(A(2 downto 0))) & "0000000"  -- Gameport
             when GAMEPORT_SELECT = '1' else
          rom_out when ROM_SELECT = '1' else  -- ROMs
          psg_do when (devselect(4) = '1' or ioselect(4) = '1') and mb_enabled = '1' else
          PD;                           -- Peripherals

  VBL <= VBL_REG;

  timing : entity work.timing_generator port map (
    CLK_14M        => CLK_14M,
    VID7M          => CLK_7M,
    CAS_N          => CAS_N,
    RAS_N          => RAS_N,
    Q3	           => Q3,
    AX             => AX,
    PHI0           => PHASE_ZERO,
    PRE_PHI0       => PRE_PHASE_ZERO_sig,
    COLOR_REF      => COLOR_REF,
    TEXT_MODE      => TEXT_MODE,
    PAGE2          => PAGE2,
    HIRES_MODE     => HIRES_MODE,
    MIXED_MODE     => MIXED_MODE,
    COL80          => COL80,
    VID7           => VIDEO_DL(7),
    VIDEO_ADDRESS  => VIDEO_ADDRESS,
    H0             => H0,
    SEGA           => SEGA,
    SEGB           => SEGB,
    SEGC           => SEGC,
    GR1            => COLOR_LINE,
    GR2            => GR2,
    VBL            => VBL_REG,
    HBL            => HBL,
    BLANK          => BLANK,
    LDPS_N         => LDPS_N);

  video_display : entity work.video_generator port map (
    CLK_14M    => CLK_14M,
    CLK_7M     => CLK_7M,
    GR2        => GR2,
    SEGA         => SEGA,
    SEGB         => SEGB,
    SEGC         => SEGC,
    ALTCHAR      => ALTCHAR,
    BLANK      => BLANK,
    DL         => VIDEO_DL,
    LDPS_N     => LDPS_N,
    FLASH_CLK  => FLASH_CLK,
    VIDEO      => VIDEO);

  we <= not T65_WE_N when cpu = '0' else not R65C02_WE_N;
  A <= unsigned(T65_A(15 downto 0)) when cpu = '0' else R65C02_A;
  D_OUT <= unsigned(T65_DO) when cpu = '0' else R65C02_DO;
  T65_DI <= std_logic_vector(D_OUT) when T65_WE_N = '0' else std_logic_vector(D_IN);
  CPU_EN <= '1' when PHASE_ZERO_D = '1' and PHASE_ZERO = '0' else '0';

  cpu_enable: process (CLK_14M)
  begin
    if rising_edge(CLK_14M) then
      PHASE_ZERO_D <= PHASE_ZERO;
      CPU_EN_POST <= CPU_EN;
    end if;
  end process cpu_enable;

  cpu6502 : entity work.T65
    port map (
      mode     => "00",
      clk      => CLK_14M,
      enable   => CPU_EN,
      res_n    => not reset,

      IRQ_n    => psg_irq_n,
      NMI_n    => '1',
      R_W_n    => T65_WE_N,
      A        => T65_A,
      DI       => T65_DI,
      DO       => T65_DO
    );

  cpu65c02: entity work.R65C02
    port map (
        reset => not reset,
        clk => CLK_14M,
        enable => CPU_EN,
        nmi_n => '1',
        irq_n => psg_irq_n,
        di => D_IN,
        do => R65C02_DO,
        addr => R65C02_A,
        nwe => R65C02_WE_N
    );

  -- Original Apple had asynchronous ROMs.  We use a synchronous ROM
  -- that needs its address earlier, hence the odd clock.
  roms : work.spram
  generic map (14,8,"../roms/apple2e.mif")
  port map (
   address => std_logic_vector(rom_addr),
   clock => CLK_14M,
   data => (others=>'0'),
   wren => '0',
   unsigned(q) => rom_out);
    
  -- ramcard  
  ram_card_D: component ramcard
    port map
    (
      mclk28 => CLK_14M,
      reset_in => reset,
      PAGE2 => PAGE2,
      HIRES => HIRES_MODE,
      RAMRD => RAMRD,
      RAMWRT => RAMWRT,
      ALTZP => ALTZP,
      STORE80 => STORE80,
      addr => std_logic_vector(A),
      video_addr => std_logic_vector(VIDEO_ADDRESS),
      unsigned(ram_addr) => card_addr,
      unsigned(video_ram_addr) => card_video_addr,
      we => we,
      card_ram_we => card_ram_we,
      card_ram_rd => card_ram_rd,
      bank1 => open
    );

    ram_card_read  <= ROM_SELECT and card_ram_rd;
    ram_card_write <= ROM_SELECT and card_ram_we;
    
  mb : work.mockingboard
    port map (
      CLK_14M    => CLK_14M,
      PHASE_ZERO => PHASE_ZERO,
      I_RESET_L => not reset,
      I_ENA_H   => mb_enabled,
      
      I_ADDR    => std_logic_vector(A)(7 downto 0),
      I_DATA    => std_logic_vector(D_OUT),
      unsigned(O_DATA)    => psg_do,
      I_RW_L    => not we,
      I_IOSEL_L => not ioselect(4),
      O_IRQ_L   => psg_irq_n,
      O_AUDIO_L => laudio,
      O_AUDIO_R => raudio
      );
    
end rtl;
