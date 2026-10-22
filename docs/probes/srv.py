import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",18081)); s.listen(1)
conn,_=s.accept(); data=conn.recv(65536).decode("latin1")
print("=== request received by loopback server ==="); print(data)
conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"); conn.close()
