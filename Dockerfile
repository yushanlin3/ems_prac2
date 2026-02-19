# Etapa 1: build con Maven
FROM maven:3.9-eclipse-temurin-8 AS build
WORKDIR /app
COPY pom.xml .
COPY src ./src
RUN mvn -B -DskipTests package

# Etapa 2: runtime
FROM eclipse-temurin:8-jre
WORKDIR /app
# Spring Boot suele dejar el artefacto en /target. Copiamos el .jar o .war generado
COPY --from=build /app/target/*.war /app/app.war
EXPOSE 8080
ENTRYPOINT ["java","-jar","/app/app.war"]
