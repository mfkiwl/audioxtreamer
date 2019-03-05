library IEEE;
  use IEEE.STD_LOGIC_1164.all;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
  use IEEE.NUMERIC_STD.all;
  use ieee.std_logic_unsigned.all;

  use work.common_types.all;

------------------------------------------------------------------------------------------------------------

entity fifo_to_m_axis is
  generic(
    max_sdi_lines  : positive := 16
  );
  port (
    clk : in STD_LOGIC;
    reset : in STD_LOGIC;

    m_axis_tvalid: out std_logic;
    --s_axis_tlast : in std_logic;
    m_axis_tready: in std_logic;
    m_axis_tdata : out STD_LOGIC_VECTOR(15 downto 0);

    nr_inputs: in std_logic_vector(3 downto 0);
    nr_padding: in slv_8;
    nr_samples: in slv_8;
    tx_enable : in std_logic;

    status_1 : in slv_8;
    status_2 : in slv_8;
    in_fifo_empty: in std_logic;
    in_fifo_rd   : out std_logic;
    in_fifo_data : in slv24_array(0 to (max_sdi_lines*2)-1)
  );
end fifo_to_m_axis;

architecture Behavioral of fifo_to_m_axis is

  constant header_size : natural := 3;
  constant max_padding : natural := 255; -- number of words (fifo writes)
  constant max_samples : natural := 255; -- number depends on the msb of the ch count 0 -> x4, 1 -> x1

  type tx_state_type is (txst_idle, txst_header, txst_data );
  signal tx_state : tx_state_type := txst_idle;

  constant header : slv16_array (0 to 2) := (X"AA55",X"0000",X"00FF");-- 3rd and 4th bytes are sampling rate and response data

  signal word_counter : natural range 0 to header_size + max_padding + 3*max_sdi_lines*max_samples ;
  signal nr_ins : natural range 0 to max_sdi_lines;
  signal padding: natural range 0 to max_padding;
  signal samples_pp: natural range 0 to max_samples;
  signal in_fifo_index: natural range 0 to (max_sdi_lines*2)-1;
  signal fifo_rd   : std_logic;
  ------------------------------------------------------------------------------------------------------------
  -- logic analyzer
  attribute mark_debug : string;
  attribute keep : string;
  attribute mark_debug of tx_state    : signal is "true";
  attribute mark_debug of in_fifo_rd  : signal is "true";
  attribute mark_debug of in_fifo_empty : signal is "true";
  attribute mark_debug of word_counter: signal is "true";

  ------------------------------------------------------------------------------------------------------------
begin

  nr_ins <= to_integer(unsigned(nr_inputs)) + 1;
  samples_pp <= to_integer(unsigned(nr_samples));
  padding <= to_integer(unsigned(nr_padding));

  tx_fsm: process (clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then 
        tx_state <= txst_idle;
        fifo_rd <= '0';
      else
        case tx_state is
          when txst_idle => 
            if tx_enable = '1' and samples_pp /= 0 and in_fifo_empty = '0' then
              tx_state <= txst_header;
              fifo_rd <= '1';
            end if;
          when txst_header => 
            fifo_rd <= '0';
            if word_counter =  header_size + padding -1 and m_axis_tready = '1' then
              tx_state <= txst_data;
            end if;
          when txst_data =>
            fifo_rd <= '0';
            if word_counter =  (samples_pp*nr_ins*3) -1  and m_axis_tready = '1' then
              if nr_ins /= 0 and in_fifo_empty = '0' then 
                tx_state <= txst_header;
                fifo_rd <= '1';
              else
                tx_state <= txst_idle;
              end if;
            end if;
          --when txst_last =>
          --  tx_state <= txst_idle;
        end case;
      end if;
    end if;
  end process;

  ------------------------------------------------------------------------------------------------------------
  tvalid_proc: process (clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        m_axis_tvalid <= '0';
      else
        case tx_state is
          when txst_idle => 
            m_axis_tvalid <= '0';
          when txst_header => 
            m_axis_tvalid <= '1';
          when txst_data =>
            if (in_fifo_index/2 = nr_ins-1 and (word_counter mod 3) = 2) then
              if word_counter < samples_pp*nr_ins*3 - 1 then
                m_axis_tvalid <= not in_fifo_empty;
              end if;
            else
              m_axis_tvalid <= '1';
            end if;
        end case;
      end if;
    end if;
  end process;

  --m_axis_tvalid <= '1' when tx_state /= txst_idle else '0';

  ------------------------------------------------------------------------------------------------------------

  in_fifo_rd <= '1' when fifo_rd = '1' or (in_fifo_empty = '0' and m_axis_tready = '1' and in_fifo_index/2 = nr_ins-1 and (word_counter mod 3) = 2  ) else '0';

  ------------------------------------------------------------------------------------------------------------
  progress_counter : process (clk)
  begin
    if rising_edge(clk) then  
      if reset = '1' then
        word_counter <= 0;
      else
        case tx_state is
          when txst_idle => 
            word_counter <= 0;
          when txst_header =>
            if m_axis_tready = '1' then
              if word_counter < header_size + padding -1 then
                word_counter <= word_counter +1;
              else
                word_counter <= 0;
              end if;
            end if;
          when txst_data =>
            if m_axis_tready = '1' then
              if word_counter < samples_pp*nr_ins*3 - 1 then
                 -- the sample is finished and we need to fetch a new sample from the fifo
                if not (in_fifo_index/2 = nr_ins-1 and (word_counter mod 3) = 2) or in_fifo_empty = '0' then
                  word_counter <= word_counter +1;
                end if;
              else
                word_counter <= 0;
              end if;
            end if;
          when others =>
        end case;
      end if;
    end if;
  end process;
  ------------------------------------------------------------------------------------------------------------
  tx_data_reg : process (clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then 
        m_axis_tdata <= X"CDCD";
      elsif tx_state /= txst_idle and m_axis_tready = '1' then
        if tx_state = txst_header then
          case word_counter is

            when 0 | header_size - 1 =>
              m_axis_tdata <= header(word_counter);
            when 1 =>
              m_axis_tdata <= status_2 & status_1;
             when others =>
              m_axis_tdata <= X"CDCD";
          end case;
        elsif tx_state = txst_data then
          case (word_counter mod 3) is
            when 0 => 
              m_axis_tdata <= in_fifo_data(in_fifo_index)(15 downto 0);
            when 1 =>
              m_axis_tdata <= in_fifo_data(in_fifo_index+1)(7 downto 0) & in_fifo_data(in_fifo_index)(23 downto 16);
            when 2 => 
              m_axis_tdata <= in_fifo_data(in_fifo_index+1)(23 downto 8);
            when others => 
              m_axis_tdata <= X"CACA";
          end case;
        else
          m_axis_tdata <= X"ADBA";
        end if;
      end if;
    end if;
  end process;
  ------------------------------------------------------------------------------------------------------------
  fifo_index : process (clk)
  begin
    if rising_edge(clk) then
      if tx_state = txst_data then 
        if m_axis_tready = '1' and  (word_counter mod 3) = 2 then
          if in_fifo_index/2 = nr_ins-1 then
            if in_fifo_empty = '0' then
              in_fifo_index <= 0;
            end if;
          else
            in_fifo_index <= in_fifo_index+2;
          end if;
        end if;
      else
        in_fifo_index <= 0;
      end if;
    end if;
  end process;
  ------------------------------------------------------------------------------------------------------------

end architecture;