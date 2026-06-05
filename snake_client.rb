require 'ruby2d'    # para a janela gráfica do jogo
require 'websocket' # para comunicação WebSocket
require 'socket'    # para a ligação TCP
require 'json'      # para enviar e receber dados em JSON

# usa o IP passado como argumento ou pede ao utilizador
if ARGV[0]
  server_ip = ARGV[0]  # IP passado ao reiniciar sem pedir novamente
else
  print "IP do servidor (ex: 192.168.193.226): "
  server_ip = gets.chomp
end

# configurações da janela
set title: 'Snake'
set width: 600
set height: 600
set background: 'black'
set fps_cap: 10

BLOCK_SIZE = 20  # tamanho de cada bloco da cobra
FOOD_SIZE = 20   # tamanho da comida normal

# liga ao servidor
socket = TCPSocket.new(server_ip, 3000)

# handshake WebSocket
handshake = WebSocket::Handshake::Client.new(url: "ws://#{server_ip}:3000")
socket.write(handshake.to_s)
socket.gets("\r\n\r\n")

puts "Ligado ao servidor!"

game_state = {}   # estado do jogo recebido do servidor
player_id = nil   # id do jogador nesta sessão
direction = 'right'  # direção inicial da cobra

# thread para receber o estado do servidor
Thread.new do
  incoming = WebSocket::Frame::Incoming::Client.new
  loop do
    begin
      data = socket.recv(4096)
      break if data.nil? || data.empty?
      incoming << data
      while (msg = incoming.next)
        parsed = JSON.parse(msg.data)
        if parsed['type'] == 'welcome'
          # recebe o id do jogador ao entrar
          player_id = parsed['id']
          puts "És o jogador #{player_id + 1}!"
        elsif parsed['type'] == 'state'
          # atualiza o estado do jogo
          game_state = parsed
        end
      end
    rescue
      break
    end
  end
end

# loop principal — corre a cada frame
update do
  clear  # limpa o ecrã

  # envia a direção ao servidor
  begin
    input = { direction: direction }
    frame = WebSocket::Frame::Outgoing::Client.new(version: 13, data: JSON.generate(input), type: :text)
    socket.write(frame.to_s)
  rescue
  end

  next if game_state.empty?  # espera pelo primeiro estado

  # desenha as comidas
  game_state['foods']&.each do |food|
    if food['golden']
      # comida dourada é maior e amarela com uma estrela
      Square.new(x: food['x'], y: food['y'], size: FOOD_SIZE + 10, color: 'yellow')
      Text.new('★', x: food['x'] + 5, y: food['y'], size: 15, color: 'white')
    else
      # comida normal é branca
      Square.new(x: food['x'], y: food['y'], size: FOOD_SIZE, color: 'white')
    end
  end

  # desenha a bola maluca
  if game_state['crazy_ball']
    ball = game_state['crazy_ball']
    Circle.new(x: ball['x'] + BLOCK_SIZE / 2, y: ball['y'] + BLOCK_SIZE / 2, radius: BLOCK_SIZE / 2, color: 'white')
  end

  # desenha todas as cobras
  game_state['snakes']&.each do |id, snake|
    next unless snake['alive']
    is_me = id.to_i == player_id  # verifica se é a tua cobra
    head_color = is_me ? 'lime' : snake['color']  # tua cabeça é verde lima
    body_color = snake['color']

    snake['body'].each_with_index do |segment, index|
      color = index == 0 ? head_color : body_color
      Square.new(x: segment['x'], y: segment['y'], size: BLOCK_SIZE, color: color)
    end
  end

  # mostra game over se o teu jogador morreu
  if player_id && game_state['snakes'] && game_state['snakes'][player_id.to_s] && !game_state['snakes'][player_id.to_s]['alive']
    Text.new("Game Over!", x: 200, y: 250, size: 30, color: 'red')
    Text.new("Prime R para reiniciar", x: 150, y: 300, size: 20, color: 'white')
  end

  # mostra as pontuações de todos os jogadores
  game_state['snakes']&.each_with_index do |(id, snake), i|
    label = id.to_i == player_id ? "(tu)" : ""
    status = snake['alive'] ? "P#{id.to_i + 1}#{label}: #{snake['score']}" : "P#{id.to_i + 1}#{label}: MORTO"
    Text.new(status, x: 10 + (i * 150), y: 10, size: 15, color: snake['color'])
  end
end

# controlos — setas ou WASD para mover
on :key_held do |event|
  case event.key
  when 'up', 'w'    then direction = 'up'
  when 'down', 's'  then direction = 'down'
  when 'left', 'a'  then direction = 'left'
  when 'right', 'd' then direction = 'right'
  end
end

on :key_down do |event|
  # reinicia o cliente ao pressionar R sem pedir o IP novamente
  if event.key == 'r' && player_id && game_state['snakes'] && game_state['snakes'][player_id.to_s] && !game_state['snakes'][player_id.to_s]['alive']
    exec("ruby snake_client.rb #{server_ip}")
  end
end

show  # mostra a janela e inicia o jogo
