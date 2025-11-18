UrbanFleet - Sistema de Gestión de Taxis
Sistema multiplayer en tiempo real que simula una flota de taxis urbanos. Desarrollado en Elixir para la clase de Programación III.

¿Qué hace?
Básicamente es un juego/simulación donde varios usuarios se conectan desde la terminal y pueden ser clientes o conductores. Los clientes piden viajes, los conductores los aceptan, y todos van acumulando puntos según qué tan bien les va.
Todo funciona en tiempo real con múltiples usuarios conectados al mismo tiempo
Cada viaje es un proceso independiente que corre en paralelo
Usa GenServers y supervisores dinámicos (lo típico de Elixir/OTP)
Los datos se guardan en archivos planos (.dat y .log)
Tiene sistema de puntuación y ranking global

¿Cómo funciona?
Te conectas con connect usuario contraseña
Si eres cliente, pides un viaje con request_trip origen=Parque destino=Centro
Si eres conductor, ves los viajes disponibles con list_trips y aceptas uno
El coductor y el cliente pueden cancelar viajes con cancel <id>
Al terminar, ambos ganan puntos (o pierdes si nadie acepta tu viaje)

Puntos:
Cliente completa viaje: +10 pts
Conductor completa viaje: +15 pts
Viaje expira sin conductor: -5 pts para el cliente

Todo queda registrado en results.log con fecha, usuarios involucrados y estado del viaje.
Stack

Elixir
OTP (GenServers, DynamicSupervisor)
Persistencia en archivos de texto

Proyecto final para Ingeniería de Sistemas - Universidad del Quindío
