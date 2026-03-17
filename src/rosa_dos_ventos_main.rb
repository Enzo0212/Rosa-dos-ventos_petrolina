require 'gosu'
require 'csv'
require 'date'

# --- CONSTANTES E FUNÇÕES GLOBAIS ---
SETORES = 16
ANGULO_POR_SETOR = 360.0 / SETORES
DIRECOES = %w[N NNE NE ENE E ESE SE SSE S SSO SO OSO O ONO NO NNO]
DENSIDADE_DO_AR = 1.18 # kg/m^3 (ao nível do mar, 15°C)

# Converte um ângulo de bússola (0=N, 90=E) para o índice do setor
def angulo_para_setor(angulo)
  angulo_normalizado = (angulo + ANGULO_POR_SETOR / 2) % 360
  (angulo_normalizado / ANGULO_POR_SETOR).to_i % SETORES
end

# --- Função de Processamento de Dados (Global) ---
def process_wind_data(data_inicio, data_fim, altura_escolhida)
  coluna_vel_vento = altura_escolhida == 25 ? 4 : 7
  coluna_dir_vento = altura_escolhida == 25 ? 5 : 8

  velocidades_por_setor = Hash.new { |hash, key| hash[key] = [] }
  soma_cubo_velocidades_por_setor = Hash.new(0.0) # Para o cálculo da potência

  arquivos = Dir.glob("PTR10??WD.csv").sort

  return nil, nil, nil, nil, "Nenhum arquivo CSV encontrado no padrão 'PTR10??WD.csv'." if arquivos.empty?

  arquivos.each do |arquivo|
    CSV.foreach(arquivo, headers: false, col_sep: ';', encoding: 'UTF-8') do |linha|
      begin
        data_str = linha[2].to_s.strip
        next if data_str.empty?

        # Tenta múltiplos formatos comuns antes de falhar
        data_csv = nil
        begin
          data_csv = DateTime.strptime(data_str, "%Y-%m-%d %H:%M:%S")
        rescue ArgumentError
          begin
            data_csv = DateTime.strptime(data_str, "%Y/%m/%d %H:%M:%S") # Tenta YYYY/MM/DD
          rescue ArgumentError
            begin
              data_csv = DateTime.strptime(data_str, "%d-%m-%Y %H:%M:%S") # Tenta DD-MM-YYYY
            rescue ArgumentError
              begin
                data_csv = DateTime.strptime(data_str, "%d/%m/%Y %H:%M:%S") # Tenta DD/MM/YYYY
              rescue ArgumentError
                next # Ignora se nenhum formato conhecido funcionar
              end
            end
          end
        end
        next unless data_csv # Pula se a data ainda for nula

        data_apenas = data_csv.to_date

        if data_apenas >= data_inicio && data_apenas <= data_fim
          vel_vento = linha[coluna_vel_vento].to_f
          dir_vento = linha[coluna_dir_vento].to_f

          setor = angulo_para_setor(dir_vento)
          velocidades_por_setor[setor] << vel_vento # Adiciona a velocidade ao array do setor
          soma_cubo_velocidades_por_setor[setor] += (vel_vento**3) #  Soma do cubo da velocidade
        end
      rescue ArgumentError
        next # Ignora linhas com formato de data inválido (já mais específica acima)
      rescue => e
        
        next
      end
    end
  end

  # Calcule freq_por_setor e soma_vel_por_setor a partir de velocidades_por_setor
  freq_por_setor = Hash.new(0)
  soma_vel_por_setor = Hash.new(0.0)

  velocidades_por_setor.each do |setor, velocidades|
    freq_por_setor[setor] = velocidades.count
    soma_vel_por_setor[setor] = velocidades.sum
  end

  if freq_por_setor.values.sum.zero?
    return nil, nil, nil, nil, "Nenhum dado encontrado no intervalo e altura selecionados!"
  end

  # Retorne também o hash de velocidades por setor e soma_cubo_velocidades_por_setor
  return freq_por_setor, soma_vel_por_setor, velocidades_por_setor, soma_cubo_velocidades_por_setor, nil
end

# --- CLASSE BASE PARA TELAS (States) ---
class GameState
  attr_reader :window

  def initialize(window)
    @window = window
  end

  def update; end
  def draw; end
  def button_down(id); end
  def needs_cursor?; true; end
end

# --- CLASSE WindRoseDisplayScreen PARA EXIBIR E INTERAGIR COM A ROSA DOS VENTOS ---
class WindRoseDisplayScreen < GameState
  def initialize(window, initial_freq, initial_soma_vel, initial_velocidades_por_setor, initial_soma_cubo_velocidades_por_setor, initial_data_inicio, initial_data_fim, initial_altura)
    super(window)
    @freq = initial_freq || Hash.new(0)
    @soma_vel = initial_soma_vel || Hash.new(0.0)
    @velocidades_por_setor = initial_velocidades_por_setor || Hash.new { |hash, key| hash[key] = [] }
    @soma_cubo_velocidades_por_setor = initial_soma_cubo_velocidades_por_setor || Hash.new(0.0) # NOVO
    @data_inicio = initial_data_inicio
    @data_fim = initial_data_fim
    @altura = initial_altura

    # Elementos de interface do usuário para filtragem
    @font_main = Gosu::Font.new(45, name: "Arial Bold")
    @font_info = Gosu::Font.new(35, name: "Arial")
    @font_tooltip = Gosu::Font.new(40, name: "Arial Bold")
    @font_input = Gosu::Font.new(30, name: "Arial")
    @font_processing = Gosu::Font.new(60, name: "Arial Bold") # New font for processing message

    # Campos de entrada para datas
    @input_date_inicio = Gosu::TextInput.new
    @input_date_inicio.text = @data_inicio.strftime('%Y-%m-%d')
    @input_date_fim = Gosu::TextInput.new
    @input_date_fim.text = @data_fim.strftime('%Y-%m-%d')
    @active_field = nil # To track which input field is active

    @message = "" # Mensagem para feedback de usuário
    @message_color = Gosu::Color::RED

    @processing_data = false # Variável de estado

    # Modo de exibição da frequência (absoluta ou relativa)
    @display_mode = :absolute 

    # Parametros para desenho da rosa dos ventos
    @center_x = @window.width / 2 + 60 
    @center_y = @window.height / 2 + 10 

    @raio_max = 365
    @max_freq = @freq.values.max.to_f.nonzero? || 1
    @total_freq = @freq.values.sum.to_f.nonzero? || 1 # Para calculo de frequencia relativa

    # Variável para a frequência relativa máxima
    @max_relative_freq = calculate_max_relative_freq
    @setor_ativo = nil
  end

  def update
    if @processing_data
      process_and_update_display
      @processing_data = false 
      return 
    end

    dx = @window.mouse_x - @center_x
    dy = @window.mouse_y - @center_y
    distancia_do_centro = Math.sqrt(dx**2 + dy**2)

    if distancia_do_centro <= @raio_max + 60
      angulo_mouse_rad = Math.atan2(-dy, dx)
      angulo_mouse_graus = (90 - (angulo_mouse_rad * 180 / Math::PI)) % 360
      @setor_ativo = angulo_para_setor(angulo_mouse_graus)
    else
      @setor_ativo = nil
    end
  end

  def draw
    @window.draw_rect(0, 0, @window.width, @window.height, Gosu::Color::WHITE)

    draw_ui_elements # Desenha os campos de entrada e botões
    desenhar_guias_circulares
    desenhar_setores
    desenhar_rotulos_direcao
    desenhar_informacoes_contextuais # Informações do período e altura
    desenhar_tooltip if @setor_ativo && @freq[@setor_ativo].to_i > 0

    # sobreposicao de processamento
    if @processing_data
      Gosu.draw_rect(0, 0, @window.width, @window.height, Gosu::Color.rgba(0, 0, 0, 150), 999)
      text = "Processando dados... Por favor, aguarde."
      text_width = @font_processing.text_width(text)
      @font_processing.draw_text(text, @window.width / 2 - text_width / 2, @window.height / 2 - 30, 1000, 1, 1, Gosu::Color::WHITE)
    end
  end

  def button_down(id)
    mouse_x = @window.mouse_x
    mouse_y = @window.mouse_y

    # Coordenadas
    ui_left_x = 20
    
    y_row1 = 60
    
    y_row2 = y_row1 + 100 
    
    y_freq_buttons = y_row2 + 100

    case id
    when Gosu::MS_LEFT
      clicked_on_ui = false

      # Verificar inout de datas
      if mouse_x.between?(ui_left_x + 80, ui_left_x + 80 + 200) && mouse_y.between?(y_row1, y_row1 + 40) # Data Início
        @window.text_input = @input_date_inicio
        @active_field = :data_inicio
        clicked_on_ui = true
      elsif mouse_x.between?(ui_left_x + 80, ui_left_x + 80 + 200) && mouse_y.between?(y_row2, y_row2 + 40) # Data Fim
        @window.text_input = @input_date_fim
        @active_field = :data_fim
        clicked_on_ui = true
      # Altitude
      elsif mouse_x.between?(1640, 1640 + 100) && mouse_y.between?(130, 130 + 40) # Botão 25m
        @altura = 25
        @message = ""
        @window.text_input = nil
        clicked_on_ui = true
      elsif mouse_x.between?(1760, 1760 + 100) && mouse_y.between?(130, 130 + 40) # Botão 50m
        @altura = 50
        @message = ""
        @window.text_input = nil
        clicked_on_ui = true
      # Filtros
      elsif mouse_x.between?(1650, 1650 + 200) && mouse_y.between?(60, 60 + 40) # Botão "Aplicar Filtros"
        @processing_data = true
        @message = "Iniciando processamento..."
        @message_color = Gosu::Color::BLUE
        @window.text_input = nil
        clicked_on_ui = true
      # Botão de navegação dia - Data Início
      elsif mouse_x.between?(ui_left_x + 50, ui_left_x + 80) && mouse_y.between?(y_row1 + 50, y_row1 + 80) 
        navigate_day_inicio(-1)
        clicked_on_ui = true
      elsif mouse_x.between?(ui_left_x + 280, ui_left_x + 310) && mouse_y.between?(y_row1 + 50, y_row1 + 80) 
        navigate_day_inicio(1)
        clicked_on_ui = true
      # Botão de navegação dia - Data Fim
      elsif mouse_x.between?(ui_left_x + 50, ui_left_x + 80) && mouse_y.between?(y_row2 + 50, y_row2 + 80) 
        navigate_day_fim(-1)
        clicked_on_ui = true
      elsif mouse_x.between?(ui_left_x + 280, ui_left_x + 310) && mouse_y.between?(y_row2 + 50, y_row2 + 80) 
        navigate_day_fim(1)
        clicked_on_ui = true
      # Botão de navegação mes - Data Início
      elsif mouse_x.between?(ui_left_x + 20, ui_left_x + 50) && mouse_y.between?(y_row1 + 50, y_row1 + 80) 
        navigate_month_inicio(-1)
        clicked_on_ui = true
      elsif mouse_x.between?(ui_left_x + 310, ui_left_x + 340) && mouse_y.between?(y_row1 + 50, y_row1 + 80) 
        navigate_month_inicio(1)
        clicked_on_ui = true
      # Botão de navegação mes - Data Fim
      elsif mouse_x.between?(ui_left_x + 20, ui_left_x + 50) && mouse_y.between?(y_row2 + 50, y_row2 + 80) 
        navigate_month_fim(-1)
        clicked_on_ui = true
      elsif mouse_x.between?(ui_left_x + 310, ui_left_x + 340) && mouse_y.between?(y_row2 + 50, y_row2 + 80) 
        navigate_month_fim(1)
        clicked_on_ui = true
      # Frequencia
      elsif mouse_x.between?(ui_left_x + 80, ui_left_x + 80 + 150) && mouse_y.between?(y_freq_buttons, y_freq_buttons + 40) # Absoluta
        @display_mode = :absolute
        @message = ""
        clicked_on_ui = true
      elsif mouse_x.between?(ui_left_x + 240, ui_left_x + 240 + 150) && mouse_y.between?(y_freq_buttons, y_freq_buttons + 40) # Relativa
        @display_mode = :relative
        @message = ""
        clicked_on_ui = true
      end

      # Verificação para clique rosa dos ventos
      unless clicked_on_ui
        dx = mouse_x - @center_x
        dy = mouse_y - @center_y
        distancia_do_centro = Math.sqrt(dx**2 + dy**2)

        if distancia_do_centro <= @raio_max + 60 && @setor_ativo && @freq[@setor_ativo].to_i > 0
          velocidades_para_histograma = @velocidades_por_setor[@setor_ativo]
          direcao_do_setor = DIRECOES[@setor_ativo]
          if velocidades_para_histograma.any?
            @window.prev_state = self # Armazena a tela atual antes de mudar
            @window.current_state = WindHistogramScreen.new(
              @window,
              @setor_ativo,
              velocidades_para_histograma,
              direcao_do_setor,
              @data_inicio,
              @data_fim,
              @altura
            )
          else
            @message = "Nenhuma ocorrência de vento neste setor para exibir histograma."
            @message_color = Gosu::Color::ORANGE
          end
        else # Clique fora da rosa
          @window.text_input = nil
          @active_field = nil
        end
      end
    when Gosu::KB_RETURN, Gosu::KB_ENTER 
      if @window.text_input == @input_date_inicio || @window.text_input == @input_date_fim || @active_field 
        @processing_data = true
        @message = "Iniciando processamento..."
        @message_color = Gosu::Color::BLUE
        @window.text_input = nil
        @active_field = nil
      end
    when Gosu::KB_ESCAPE
      @window.close # Fecha a janela
    when Gosu::KB_S
      @window.screenshot("rosa_dos_ventos_analise_#{Time.now.strftime('%Y%m%d_%H%M%S')}.png")
      puts "📷 Imagem da Rosa dos Ventos salva com sucesso!"
    end
  end

  private

  def process_and_update_display
    begin
      new_data_inicio = parse_date_input(@input_date_inicio.text)
      new_data_fim = parse_date_input(@input_date_fim.text)

      if new_data_inicio.nil? || new_data_fim.nil?
        @message = "Formato de data inválido. Use AAAA-MM-DD, AAAA/MM/DD, DD-MM-YYYY ou DD/MM/YYYY."
        @message_color = Gosu::Color::RED
        return
      end

      if new_data_inicio > new_data_fim
        @message = "Data inicial não pode ser maior que a final!"
        @message_color = Gosu::Color::RED
        return
      end

      #Recebe o terceiro e quarto retorno: velocidades_por_setor e soma_cubo_velocidades_por_setor
      freq, soma_vel, velocidades_por_setor, soma_cubo_velocidades_por_setor, error_message = process_wind_data(new_data_inicio, new_data_fim, @altura)

      if error_message
        @message = error_message
        @message_color = Gosu::Color::ORANGE
      else
        @freq = freq
        @soma_vel = soma_vel
        @velocidades_por_setor = velocidades_por_setor # Atribui o novo hash
        @soma_cubo_velocidades_por_setor = soma_cubo_velocidades_por_setor # Atribui o novo hash
        @data_inicio = new_data_inicio
        @data_fim = new_data_fim
        @max_freq = @freq.values.max.to_f.nonzero? || 1
        @total_freq = @freq.values.sum.to_f.nonzero? || 1
        @max_relative_freq = calculate_max_relative_freq 
        @message = "Dados atualizados!"
        @message_color = Gosu::Color.new(0, 150, 0) # Verde para sucesso
      end
    rescue => e
      @message = "Erro inesperado ao processar: #{e.message}"
      @message_color = Gosu::Color::RED
      puts "Erro detalhado: #{e.message}\n#{e.backtrace.join("\n")}"
    ensure
      @processing_data = false 
    end
  end

  # Função auxiliar para parsing de data mais robusto
  def parse_date_input(date_string)
    formats = ["%Y-%m-%d", "%Y/%m/%d", "%d-%m-%Y", "%d/%m/%Y"]
    formats.each do |format|
      begin
        return Date.strptime(date_string, format)
      rescue ArgumentError
        next
      end
    end
    nil # Retorna nil se nenhum formato funcionar
  end

  # Novo método auxiliar para calcular a frequência relativa máxima
  def calculate_max_relative_freq
    return 1.0 if @total_freq.zero? # Evita divisão por zero

    max_perc = 0.0
    @freq.each do |setor, count|
      perc = (count.to_f / @total_freq) * 100
      max_perc = [max_perc, perc].max
    end
    max_perc.nonzero? || 1.0 # Retorna 1.0 se todos forem zero para evitar divisão por zero
  end

  def draw_ui_elements
    
    ui_left_x = 20
   
    y_row1 = 60
    
    y_row2 = y_row1 + 100 
   
    y_freq_buttons = y_row2 + 100

    # --- Data Início ---
    @font_info.draw_text("Início:", ui_left_x, y_row1 + 5, 0, 1, 1, Gosu::Color::BLACK)
    input_x_inicio = ui_left_x + 80
    input_y_inicio = y_row1
    input_w = 200
    input_h = 40
    Gosu.draw_rect(input_x_inicio, input_y_inicio, input_w, input_h, Gosu::Color.rgba(220, 220, 220, 255))
    border_color = Gosu::Color::BLACK
    z_order_border = 0
    @window.draw_line(input_x_inicio, input_y_inicio, border_color, input_x_inicio + input_w, input_y_inicio, border_color, z_order_border)
    @window.draw_line(input_x_inicio + input_w, input_y_inicio, border_color, input_x_inicio + input_w, input_y_inicio + input_h, border_color, z_order_border)
    @window.draw_line(input_x_inicio + input_w, input_y_inicio + input_h, border_color, input_x_inicio, input_y_inicio + input_h, border_color, z_order_border)
    @window.draw_line(input_x_inicio, input_y_inicio + input_h, border_color, input_x_inicio, input_y_inicio, border_color, z_order_border)
    @font_input.draw_text(@input_date_inicio.text, input_x_inicio + 5, input_y_inicio + 8, 0, 1, 1, @active_field == :data_inicio ? Gosu::Color::BLUE : Gosu::Color::BLACK)

    # Botões de navegação para Data Início (abaixo do campo)
    btn_y_inicio = y_row1 + 50 # Y para os botões de data de início
    draw_button(ui_left_x + 20, btn_y_inicio, "<<", false, false, 30, 30) # Mês Anterior
    draw_button(ui_left_x + 50, btn_y_inicio, "<", false, false, 30, 30) # Dia Anterior
    draw_button(ui_left_x + 280, btn_y_inicio, ">", false, false, 30, 30) # Dia Seguinte
    draw_button(ui_left_x + 310, btn_y_inicio, ">>", false, false, 30, 30) # Mês Seguinte


    # --- Data Fim ---
    @font_info.draw_text("Fim:", ui_left_x, y_row2 + 5, 0, 1, 1, Gosu::Color::BLACK)
    input_x_fim = ui_left_x + 80
    input_y_fim = y_row2
    Gosu.draw_rect(input_x_fim, input_y_fim, input_w, input_h, Gosu::Color.rgba(220, 220, 220, 255))
    @window.draw_line(input_x_fim, input_y_fim, border_color, input_x_fim + input_w, input_y_fim, border_color, z_order_border)
    @window.draw_line(input_x_fim + input_w, input_y_fim, border_color, input_x_fim + input_w, input_y_fim + input_h, border_color, z_order_border)
    @window.draw_line(input_x_fim + input_w, input_y_fim + input_h, border_color, input_x_fim, input_y_fim + input_h, border_color, z_order_border)
    @window.draw_line(input_x_fim, input_y_fim + input_h, border_color, input_x_fim, input_y_fim, border_color, z_order_border)
    @font_input.draw_text(@input_date_fim.text, input_x_fim + 5, input_y_fim + 8, 0, 1, 1, @active_field == :data_fim ? Gosu::Color::BLUE : Gosu::Color::BLACK)

    # Botões de navegação para Data Fim (abaixo do campo)
    btn_y_fim = y_row2 + 50 # Y para os botões de data de fim
    draw_button(ui_left_x + 20, btn_y_fim, "<<", false, false, 30, 30) # Mês Anterior
    draw_button(ui_left_x + 50, btn_y_fim, "<", false, false, 30, 30) # Dia Anterior
    draw_button(ui_left_x + 280, btn_y_fim, ">", false, false, 30, 30) # Dia Seguinte
    draw_button(ui_left_x + 310, btn_y_fim, ">>", false, false, 30, 30) # Mês Seguinte

    @font_info.draw_text("Exibir:", ui_left_x, y_freq_buttons + 5, 0, 1, 1, Gosu::Color::BLACK)
    draw_button(ui_left_x + 80, y_freq_buttons, "Absoluta", @display_mode == :absolute, false, 150, 40)
    draw_button(ui_left_x + 240, y_freq_buttons, "Relativa", @display_mode == :relative, false, 150, 40)

    # Altitude Buttons (still on right side)
    draw_button(1640, 130, "25m", @altura == 25, false, 100, 40)
    draw_button(1760, 130, "50m", @altura == 50, false, 100, 40)

    apply_button_x = 1650
    apply_button_y = 60
    apply_button_w = 200
    apply_button_h = 50
    apply_button_text = "Aplicar"

    if @processing_data
      disabled_color = Gosu::Color.rgba(100, 100, 100, 255)
      @window.draw_rect(apply_button_x, apply_button_y, apply_button_w, apply_button_h, disabled_color)
      @window.draw_line(apply_button_x, apply_button_y, Gosu::Color::DK_GRAY, apply_button_x + apply_button_w, apply_button_y, Gosu::Color::DK_GRAY, z_order_border)
      @window.draw_line(apply_button_x + apply_button_w, apply_button_y, Gosu::Color::DK_GRAY, apply_button_x + apply_button_w, apply_button_y + apply_button_h, Gosu::Color::DK_GRAY, z_order_border)
      @window.draw_line(apply_button_x + apply_button_w, apply_button_y + apply_button_h, Gosu::Color::DK_GRAY, apply_button_x, apply_button_y + apply_button_h, Gosu::Color::DK_GRAY, z_order_border)
      @window.draw_line(apply_button_x, apply_button_y + apply_button_h, Gosu::Color::DK_GRAY, apply_button_x, apply_button_y, Gosu::Color::DK_GRAY, z_order_border)
      @font_input.draw_text_rel(apply_button_text, apply_button_x + apply_button_w / 2, apply_button_y + apply_button_h / 2, z_order_border, 0.5, 0.5, 1, 1, Gosu::Color::LT_GRAY)
    else
      draw_button(apply_button_x, apply_button_y, apply_button_text, false, true, apply_button_w, apply_button_h)
    end

  
    @font_info.draw_text(@message, @window.width - @font_info.text_width(@message) - 20, 10, 0, 1, 1, @message_color)
  end

  def draw_button(x, y, text, selected = false, is_apply_button = false, width = 200, height = 60)
    color = selected ? Gosu::Color.new(100, 150, 255) : Gosu::Color.new(150, 200, 255)
    text_color = Gosu::Color::BLACK

    if is_apply_button
      color = Gosu::Color.new(0, 150, 0)
      text_color = Gosu::Color::WHITE
    end

    # Hover effect
    if @window.mouse_x.between?(x, x + width) && @window.mouse_y.between?(y, y + height)
      color = Gosu::Color.new([color.red + 30, 255].min, [color.green + 30, 255].min, [color.blue + 30, 255].min)
    end

    @window.draw_rect(x, y, width, height, color)

    border_color = Gosu::Color::BLACK
    z_order_border = 1
    @window.draw_line(x, y, border_color, x + width, y, border_color, z_order_border) # Top
    @window.draw_line(x + width, y, border_color, x + width, y + height, border_color, z_order_border) # Right
    @window.draw_line(x + width, y + height, border_color, x, y + height, border_color, z_order_border) # Bottom
    @window.draw_line(x, y + height, border_color, x, y, border_color, z_order_border) # Left

    @font_input.draw_text_rel(text, x + width / 2, y + height / 2, z_order_border, 0.5, 0.5, 1, 1, text_color)
  end

  def navigate_month_inicio(direction)
    current_date = parse_date_input(@input_date_inicio.text)
    return if current_date.nil? # Para evitar erro se a data for inválida
    first_day_of_current_month = Date.new(current_date.year, current_date.month, 1)
    new_date = first_day_of_current_month.next_month(direction)
    @input_date_inicio.text = new_date.strftime('%Y-%m-%d')
    @message = "" 
  rescue ArgumentError
    @message = "Data de início inválida para navegação."
    @message_color = Gosu::Color::RED
  end

  def navigate_month_fim(direction)
    current_date = parse_date_input(@input_date_fim.text)
    return if current_date.nil? # Adicionado para evitar erro se a data for inválida
    first_day_of_current_month = Date.new(current_date.year, current_date.month, 1)
    new_date = first_day_of_current_month.next_month(direction)
    @input_date_fim.text = new_date.strftime('%Y-%m-%d')
    @message = "" 
  rescue ArgumentError
    @message = "Data de fim inválida para navegação."
    @message_color = Gosu::Color::RED
  end

  def navigate_day_inicio(direction)
    current_date = parse_date_input(@input_date_inicio.text)
    return if current_date.nil? # Adicionado para evitar erro se a data for inválida
    new_date = current_date + direction
    @input_date_inicio.text = new_date.strftime('%Y-%m-%d')
    @message = ""
  rescue ArgumentError
    @message = "Data de início inválida para navegação."
    @message_color = Gosu::Color::RED
  end

  def navigate_day_fim(direction)
    current_date = parse_date_input(@input_date_fim.text)
    return if current_date.nil? # Adicionado para evitar erro se a data for inválida
    new_date = current_date + direction
    @input_date_fim.text = new_date.strftime('%Y-%m-%d')
    @message = ""
  rescue ArgumentError
    @message = "Data de fim inválida para navegação."
    @message_color = Gosu::Color::RED
  end

  def desenhar_setores
    (0...SETORES).each do |setor|
      f = @freq[setor].to_f
      next if f.zero?

      # Calculo de raio
      current_value = case @display_mode
                      when :absolute
                        f
                      when :relative
                        (f / @total_freq) * 100 
                      end

      max_value = case @display_mode
                  when :absolute
                    @max_freq
                  when :relative
                    @max_relative_freq 
                  end

      raio_setor_atual = (current_value / max_value) * @raio_max

      cor_base = Gosu::Color.rgba(0, 100, 200, 200)
      cor_destaque = Gosu::Color.rgba(255, 60, 60, 230)

      cor = (setor == @setor_ativo) ? cor_destaque : cor_base

      @window.draw_arc(@center_x, @center_y, raio_setor_atual,
                       setor * ANGULO_POR_SETOR - ANGULO_POR_SETOR / 2,
                       setor * ANGULO_POR_SETOR + ANGULO_POR_SETOR / 2, cor)
    end
  end

  def desenhar_guias_circulares
    (0...SETORES).each do |i|
      angulo_graus = i * ANGULO_POR_SETOR - ANGULO_POR_SETOR / 2
      rad = (90 - angulo_graus) * Math::PI / 180.0
      x2 = @center_x + @raio_max * Math.cos(rad)
      y2 = @center_y - @raio_max * Math.sin(rad)
      Gosu.draw_line(@center_x, @center_y, Gosu::Color.new(200, 200, 200), x2, y2, Gosu::Color.new(200, 200, 200), 1)
    end

    @window.draw_circle(@center_x, @center_y, @raio_max, Gosu::Color.new(80, 80, 80), 1, 250)

    # @max_relative_freq para a escala dos rótulos quando em modo relativo
    scale_max_for_labels = (@display_mode == :absolute) ? @max_freq : @max_relative_freq

    [0.25, 0.5, 0.75].each do |perc|
      raio = @raio_max * perc
      @window.draw_circle(@center_x, @center_y, raio, Gosu::Color.new(120, 120, 120))

      freq_label = case @display_mode
                   when :absolute
                     ((scale_max_for_labels * perc).round(1)).to_s
                   when :relative
                     ((scale_max_for_labels * perc).round(1)).to_s + "%"
                   end

      @font_info.draw_text(freq_label, @center_x + 30, @center_y - raio - 35, 3, 1, 1, Gosu::Color::BLACK)
    end

    label_text = (@display_mode == :absolute) ? "Frequência" : "Frequência (%)"
    @font_info.draw_text(label_text, @center_x + 30, @center_y - 35, 3, 1, 1, Gosu::Color::BLACK)
  end

  def desenhar_rotulos_direcao
    (0...SETORES).each do |setor|
      angulo_central_vento = setor * ANGULO_POR_SETOR
      rad_rotulo = (90.0 - angulo_central_vento) * Math::PI / 180.0
      dist_label = @raio_max + 130
      dx = @center_x + dist_label * Math.cos(rad_rotulo)
      dy = @center_y - dist_label * Math.sin(rad_rotulo)

      offset_x = 0
      offset_y = 0
      case DIRECOES[setor]
      when "N"
        offset_y = -10
      when "S"
        offset_y = 10
      when "E"
        offset_x = 10
      when "O"
        offset_x = -10
      when "NNE", "NNW"
        offset_y = -5
      when "SSE", "SSO"
        offset_y = 5
      end

      @font_main.draw_text_rel(DIRECOES[setor], dx + offset_x, dy + offset_y, 2, 0.5, 0.5, 1, 1, Gosu::Color::BLACK)
    end
  end

  def desenhar_informacoes_contextuais
    # Período de Análise (ao lado da rosa) 
    periodo_texto = "Período: #{@data_inicio.strftime('%d/%m/%Y')} a #{@data_fim.strftime('%d/%m/%Y')}"
    @font_info.draw_text(periodo_texto, 70, @window.height - 70, 5, 1, 1, Gosu::Color.new(60,60,60))

    # Altura de Medição (ao lado da rosa) 
    altura_texto = "Altura: #{@altura} metros"
    text_width = @font_info.text_width(altura_texto)
    @font_info.draw_text(altura_texto, @window.width - text_width - 70, @window.height - 70, 5, 1, 1, Gosu::Color.new(60,60,60))
  end

  # Exibir distribuição de velocidade dentro do tooltip
  def desenhar_tooltip
    f = @freq[@setor_ativo]
    velocidades_do_setor = @velocidades_por_setor[@setor_ativo] # Obter as velocidades brutas
    soma_cubo_vel_setor = @soma_cubo_velocidades_por_setor[@setor_ativo] # Obter a soma do cubo das velocidades

    vel_media = (f.zero? ? 0 : @soma_vel[@setor_ativo] / f).round(2)
    percentual_freq = (f / @freq.values.sum.to_f * 100).round(1)

    # Calcular min, max e mediana para o tooltip
    min_vel = velocidades_do_setor.min&.round(2) || 0.0 # Use & para evitar erro se array vazio
    max_vel = velocidades_do_setor.max&.round(2) || 0.0

    sorted_velocidades = velocidades_do_setor.sort
    median_vel = if sorted_velocidades.empty?
                   0.0
                 elsif sorted_velocidades.size.odd?
                   sorted_velocidades[sorted_velocidades.size / 2].round(2)
                 else
                   ((sorted_velocidades[sorted_velocidades.size / 2 - 1] + sorted_velocidades[sorted_velocidades.size / 2]) / 2.0).round(2)
                 end

    # Cálculo da potência média por metro quadrado
    # P_media = (1/2) * rho * (sum(v^3) / count)
    potencia_media_por_m2 = if f.zero?
                              0.0
                            else
                              (0.5 * DENSIDADE_DO_AR * (soma_cubo_vel_setor / f)).round(2)
                            end

    texto1 = "Direção: #{DIRECOES[@setor_ativo]} "
    texto2 = "Freq. Absoluta: #{f} ocorrências"
    texto3 = "Freq. Relativa: #{percentual_freq}% do total"
    texto4 = "Vel. Média: #{vel_media} m/s"
    texto5 = "Vel. Max: #{max_vel} m/s"
    texto6 = "Potência Média/m²: #{potencia_media_por_m2} W/m²" # Linha para potência

    box_w = 600 # Aumentar largura para acomodar a nova linha
    box_h = 330 # Aumentar altura para acomodar a nova linha (antes 280)
    box_x = @window.mouse_x + 70
    box_y = @window.mouse_y + 70

    box_x -= (box_w + 140) if box_x + box_w > @window.width
    box_y -= (box_h + 140) if box_y + box_h > @window.height

    z_fundo = 10
    z_borda_texto = 11

    Gosu.draw_rect(box_x, box_y, box_w, box_h, Gosu::Color.rgba(240, 248, 255, 230), z_fundo)
    Gosu.draw_line(box_x, box_y, Gosu::Color::BLACK, box_x + box_w, box_y, Gosu::Color::BLACK, z_borda_texto)
    Gosu.draw_line(box_x + box_w, box_y, Gosu::Color::BLACK, box_x + box_w, box_y + box_h, Gosu::Color::BLACK, z_borda_texto)
    Gosu.draw_line(box_x + box_w, box_y + box_h, Gosu::Color::BLACK, box_x, box_y + box_h, Gosu::Color::BLACK, z_borda_texto)
    Gosu.draw_line(box_x, box_y + box_h, Gosu::Color::BLACK, box_x, box_y, Gosu::Color::BLACK, z_borda_texto)

    @font_tooltip.draw_text(texto1, box_x + 35, box_y + 30, z_borda_texto, 1, 1, Gosu::Color::BLACK)
    @font_tooltip.draw_text(texto2, box_x + 35, box_y + 80, z_borda_texto, 1, 1, Gosu::Color::BLACK)
    @font_tooltip.draw_text(texto3, box_x + 35, box_y + 130, z_borda_texto, 1, 1, Gosu::Color::BLACK)
    @font_tooltip.draw_text(texto4, box_x + 35, box_y + 180, z_borda_texto, 1, 1, Gosu::Color::BLACK)
    @font_tooltip.draw_text(texto5, box_x + 35, box_y + 230, z_borda_texto, 1, 1, Gosu::Color::BLACK)
    @font_tooltip.draw_text(texto6, box_x + 35, box_y + 280, z_borda_texto, 1, 1, Gosu::Color::BLACK) # NOVO: Desenha a potência
  end
end

# --- CLASSE WindHistogramScreen PARA EXIBIR O HISTOGRAMA DE VELOCIDADES ---
class WindHistogramScreen < GameState
  def initialize(window, setor_selecionado, velocidades_do_setor, direcao_setor, data_inicio, data_fim, altura)
    super(window)
    @setor = setor_selecionado
    @velocidades = velocidades_do_setor
    @direcao = direcao_setor
    @data_inicio = data_inicio
    @data_fim = data_fim
    @altura = altura

    @font_title = Gosu::Font.new(50, name: "Arial Bold")
    @font_labels = Gosu::Font.new(30, name: "Arial")
    @font_info = Gosu::Font.new(25, name: "Arial")

    # Parâmetros do histograma
    @margin_x = 100
    @margin_y = 100
    @graph_width = @window.width - 2 * @margin_x
    @graph_height = @window.height - 2 * @margin_y - 100 

    # Número de bins dinâmico (fórmula de Sturges)
    @num_bins = calculate_optimal_bins(@velocidades.count)

    # Campo de entrada para número de bins (opcional)
    @input_num_bins = Gosu::TextInput.new
    @input_num_bins.text = @num_bins.to_s
    @active_field = nil 

    calculate_bins # Método para calcular os bins e a frequência em cada bin

    # Back button
    @back_button_x = 20
    @back_button_y = 20
    @back_button_w = 150
    @back_button_h = 50
  end

  # Método para calcular número de bins otimizado
  def calculate_optimal_bins(num_data_points)
    return 10 if num_data_points <= 1 # Evita log(0) e poucos dados

    # Fórmula de Sturges: k = 1 + 3.322 log10(N)
    (1 + 3.322 * Math.log10(num_data_points)).round
  end

  def calculate_bins
    return if @velocidades.empty?

    # Recalcula num_bins se o input_num_bins mudou
    if @input_num_bins.text.to_i > 0
      @num_bins = @input_num_bins.text.to_i
    else
      @num_bins = calculate_optimal_bins(@velocidades.count)
    end

    @min_vel = @velocidades.min
    @max_vel = @velocidades.max
    @range_vel = @max_vel - @min_vel

    # Se o range for muito pequeno ou todas as velocidades forem iguais, defina um bin_size padrão
    if @range_vel.zero?
      @bin_size = 1.0 # Tamanho do bin fixo
      @min_vel = (@min_vel - 0.5).floor # Ajusta min_vel para ter um range visual
      @max_vel = @min_vel + @num_bins * @bin_size # Ajusta max_vel
    else
      @bin_size = @range_vel / @num_bins.to_f
    end

    @bins = Array.new(@num_bins, 0)
    @bin_labels = []

    # Criar os rótulos e popular os bins
    @num_bins.times do |i|
      lower_bound = @min_vel + i * @bin_size
      upper_bound = @min_vel + (i + 1) * @bin_size
      @bin_labels << "#{lower_bound.round(1)}-#{upper_bound.round(1)}m/s"
    end

    @velocidades.each do |vel|
      bin_index = ((vel - @min_vel) / @bin_size).floor
      bin_index = @num_bins - 1 if bin_index >= @num_bins # Garante que o valor máximo caia no último bin
      @bins[bin_index] += 1
    end

    @max_bin_freq = @bins.max.to_f.nonzero? || 1
  end

  def update
    
  end

  def draw
    @window.draw_rect(0, 0, @window.width, @window.height, Gosu::Color::WHITE)

    # Título
    title_text = "Histograma de Velocidade do Vento para #{@direcao}"
    title_width = @font_title.text_width(title_text)
    @font_title.draw_text(title_text, @window.width / 2 - title_width / 2, @margin_y / 2, 0, 1, 1, Gosu::Color::BLACK)

    # Campo de entrada para número de bins
    @font_labels.draw_text("Nº Bins:", @margin_x + @graph_width - 250, @margin_y / 2 + 10, 0, 1, 1, Gosu::Color::BLACK)
    input_x_bins = @margin_x + @graph_width - 150
    input_y_bins = @margin_y / 2
    input_w_bins = 80
    input_h_bins = 40
    Gosu.draw_rect(input_x_bins, input_y_bins, input_w_bins, input_h_bins, Gosu::Color.rgba(220, 220, 220, 255))
    border_color = Gosu::Color::BLACK
    z_order_border = 0
    @window.draw_line(input_x_bins, input_y_bins, border_color, input_x_bins + input_w_bins, input_y_bins, border_color, z_order_border)
    @window.draw_line(input_x_bins + input_w_bins, input_y_bins, border_color, input_x_bins + input_w_bins, input_y_bins + input_h_bins, border_color, z_order_border)
    @window.draw_line(input_x_bins + input_w_bins, input_y_bins + input_h_bins, border_color, input_x_bins, input_y_bins + input_h_bins, border_color, z_order_border)
    @window.draw_line(input_x_bins, input_y_bins + input_h_bins, border_color, input_x_bins, input_y_bins, border_color, z_order_border)
    @font_labels.draw_text(@input_num_bins.text, input_x_bins + 5, input_y_bins + 8, 0, 1, 1, @active_field == :num_bins ? Gosu::Color::BLUE : Gosu::Color::BLACK)

    # Botão "Aplicar Bins"
    apply_bins_btn_x = input_x_bins + input_w_bins + 10
    apply_bins_btn_y = input_y_bins
    draw_button(apply_bins_btn_x, apply_bins_btn_y, "Aplicar", false, true, 80, 40)


    # Desenhar o histograma
    draw_histogram_bars
    draw_histogram_labels

    # Informações contextuais
    info_text = "Período: #{@data_inicio.strftime('%d/%m/%Y')} a #{@data_fim.strftime('%d/%m/%Y')} | Altura: #{@altura}m | Total de Ocorrências no Setor: #{@velocidades.count}"
    info_width = @font_info.text_width(info_text)
    @font_info.draw_text(info_text, @window.width / 2 - info_width / 2, @window.height - 60, 0, 1, 1, Gosu::Color.new(60, 60, 60))

    # Botão Voltar
    draw_button(@back_button_x, @back_button_y, "Voltar", false, false, @back_button_w, @back_button_h)
  end

  def button_down(id)
    mouse_x = @window.mouse_x
    mouse_y = @window.mouse_y

    input_x_bins = @margin_x + @graph_width - 150
    input_y_bins = @margin_y / 2
    input_w_bins = 80
    input_h_bins = 40
    apply_bins_btn_x = input_x_bins + input_w_bins + 10
    apply_bins_btn_y = input_y_bins
    apply_bins_btn_w = 80
    apply_bins_btn_h = 40

    case id
    when Gosu::MS_LEFT
      if mouse_x.between?(@back_button_x, @back_button_x + @back_button_w) &&
         mouse_y.between?(@back_button_y, @back_button_y + @back_button_h)
        @window.current_state = @window.prev_state # Voltar para a tela anterior
      elsif mouse_x.between?(input_x_bins, input_x_bins + input_w_bins) && mouse_y.between?(input_y_bins, input_y_bins + input_h_bins) # Clique no campo de bins
        @window.text_input = @input_num_bins
        @active_field = :num_bins
      elsif mouse_x.between?(apply_bins_btn_x, apply_bins_btn_x + apply_bins_btn_w) && mouse_y.between?(apply_bins_btn_y, apply_bins_btn_y + apply_bins_btn_h) # Clique no botão "Aplicar Bins"
        @window.text_input = nil
        @active_field = nil
        calculate_bins # Recalcular bins
      else # Clicked outside input fields
        @window.text_input = nil
        @active_field = nil
      end
    when Gosu::KB_RETURN, Gosu::KB_ENTER # Enter key to apply bins
      if @window.text_input == @input_num_bins || @active_field == :num_bins
        @window.text_input = nil
        @active_field = nil
        calculate_bins # Recalcular bins
      end
    when Gosu::KB_ESCAPE
      @window.current_state = @window.prev_state # Voltar para a tela anterior
    when Gosu::KB_S
      @window.screenshot("histograma_vento_#{DIRECOES[@setor]}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.png")
      puts "📷 Imagem do Histograma salva com sucesso!"
    end
  end

  private

  def draw_button(x, y, text, selected = false, is_apply_button = false, width = 200, height = 60)
    color = selected ? Gosu::Color.new(100, 150, 255) : Gosu::Color.new(150, 200, 255)
    text_color = Gosu::Color::BLACK

    if is_apply_button
      color = Gosu::Color.new(0, 150, 0) 
      text_color = Gosu::Color::WHITE
    end

    # Hover effect
    if @window.mouse_x.between?(x, x + width) && @window.mouse_y.between?(y, y + height)
      color = Gosu::Color.new([color.red + 30, 255].min, [color.green + 30, 255].min, [color.blue + 30, 255].min)
    end

    @window.draw_rect(x, y, width, height, color)

    border_color = Gosu::Color::BLACK
    z_order_border = 1 
    @window.draw_line(x, y, border_color, x + width, y, border_color, z_order_border) 
    @window.draw_line(x + width, y, border_color, x + width, y + height, border_color, z_order_border) 
    @window.draw_line(x + width, y + height, border_color, x, y + height, border_color, z_order_border) 
    @window.draw_line(x, y + height, border_color, x, y, border_color, z_order_border) 

    @font_labels.draw_text_rel(text, x + width / 2, y + height / 2, z_order_border, 0.5, 0.5, 1, 1, text_color)
  end

  def draw_histogram_bars
    bar_width = @graph_width / @num_bins.to_f
    base_y = @window.height - @margin_y - 100 # Base do gráfico

    @bins.each_with_index do |freq, i|
      bar_height = (freq / @max_bin_freq) * @graph_height
      bar_x = @margin_x + i * bar_width
      bar_y = base_y - bar_height

      # Cor da barra
      bar_color = Gosu::Color.rgba(50, 150, 250, 200)
      Gosu.draw_rect(bar_x, bar_y, bar_width - 2, bar_height, bar_color) # -2 para um pequeno espaçamento

      # Borda da barra
      Gosu.draw_rect(bar_x, bar_y, bar_width - 2, bar_height, Gosu::Color::BLACK, 1) # Borda preta
    end
  end

  def draw_histogram_labels
    bar_width = @graph_width / @num_bins.to_f
    base_y = @window.height - @margin_y - 100 # Base do gráfico

    # Eixo X (rótulos dos bins)
    @bin_labels.each_with_index do |label, i|
      label_x = @margin_x + i * bar_width + bar_width / 2
      label_y = base_y + 10 # Abaixo das barras
      @font_labels.draw_text_rel(label, label_x, label_y, 0, 0.5, 0.0, 1, 1, Gosu::Color::BLACK) 
    end
    @font_labels.draw_text_rel("Velocidade (m/s)", @window.width / 2, base_y + 60, 0, 0.5, 0.0, 1, 1, Gosu::Color::BLACK) 


    # Eixo Y (frequência)
    # Linha do eixo Y
    Gosu.draw_line(@margin_x, base_y, Gosu::Color::BLACK, @margin_x, base_y - @graph_height, Gosu::Color::BLACK, 0)
    
    
    @font_labels.draw_text_rel("Frequência", @margin_x - 60, base_y - @graph_height / 2, 0, 0.5, 0.5, 1, 1, Gosu::Color::BLACK)

    # Rótulos de frequência no eixo Y
    num_labels_y = 5 # Por exemplo, 5 rótulos
    (0..num_labels_y).each do |i|
      freq_value = (@max_bin_freq / num_labels_y.to_f * i).round(0)
      label_y = base_y - (freq_value / @max_bin_freq) * @graph_height
      @font_labels.draw_text(freq_value.to_s, @margin_x - 40, label_y - @font_labels.height / 2, 0, 1, 1, Gosu::Color::BLACK)
    end
  end
end

# --- CLASSE PRINCIPAL DA JANELA GOSU ---
class WindRoseWindow < Gosu::Window
  attr_accessor :current_state
  attr_accessor :prev_state # Para armazenar a tela anterior

  def initialize
    super 1920, 1080, true
    self.caption = "Análise de Vento - Rosa dos Ventos | ESC para Sair | S para Salvar Imagem | Clique em um setor para o Histograma"

    # Define os parâmetros iniciais
    initial_data_inicio = Date.new(2010, 1, 1)
    initial_data_fim = Date.new(2010, 1, 31)
    initial_altura = 25 # Padrao para 25m

    # Processa os dados iniciais (executado uma vez no início)
    # Recebe o terceiro e quarto retorno: velocidades_por_setor e soma_cubo_velocidades_por_setor
    freq, soma_vel, velocidades_por_setor, soma_cubo_velocidades_por_setor, error_message = process_wind_data(initial_data_inicio, initial_data_fim, initial_altura)

    # Inicia diretamente com a WindRoseDisplayScreen, passando o novo parâmetro
    @current_state = WindRoseDisplayScreen.new(self, freq, soma_vel, velocidades_por_setor, soma_cubo_velocidades_por_setor, initial_data_inicio, initial_data_fim, initial_altura)
    @prev_state = nil # Inicialmente não há tela anterior

    if error_message
      @current_state.instance_variable_set(:@message, error_message)
      @current_state.instance_variable_set(:@message_color, Gosu::Color::ORANGE)
    end
  end

  def update
    @current_state.update
  end

  def draw
    @current_state.draw
  end

  def button_down(id)
    @current_state.button_down(id)
  end

  def needs_cursor?
    @current_state.needs_cursor?
  end

  # Métodos utilitários de desenho, movidos para a janela principal
  def draw_circle(cx, cy, radius, color, z = 1, segments = 250)
    (0...segments).each do |i|
      angle1 = i * 360 / segments
      angle2 = (i + 1) * 360 / segments
      rad1 = (90 - angle1) * Math::PI / 180
      rad2 = (90 - angle2) * Math::PI / 180
      x1 = cx + radius * Math.cos(rad1)
      y1 = cy - radius * Math.sin(rad1)
      x2 = cx + radius * Math.cos(rad2)
      y2 = cy - radius * Math.sin(rad2)
      Gosu.draw_line(x1, y1, color, x2, y2, color, z)
    end
  end

  def draw_arc(cx, cy, radius, angle_start, angle_end, color, z = 2, segments = 180)
    rad_start_g = (90 - angle_start) * Math::PI / 180.0
    rad_end_g = (90 - angle_end) * Math::PI / 180.0

    (0...segments).each do |i|
      current_angle = rad_end_g + i * (rad_start_g - rad_end_g) / segments
      next_angle = rad_end_g + (i + 1) * (rad_start_g - rad_end_g) / segments

      x1 = cx + radius * Math.cos(current_angle)
      y1 = cy - radius * Math.sin(current_angle)
      x2 = cx + radius * Math.cos(next_angle)
      y2 = cy - radius * Math.sin(next_angle)

      Gosu.draw_quad(
        cx, cy, color,
        x1, y1, color,
        x2, y2, color,
        cx, cy, color,
        z
      )
    end
  end
end

# --- INÍCIO DA EXECUÇÃO DO SCRIPT ---
puts "🚀 Iniciando a aplicação Gosu..."
WindRoseWindow.new.show
