# Pipeline de Integración Continua con GitHub Actions

Repositorio para el laboratorio de CI con GitHub Actions

## Descripción del laboratorio

En este laboratorio el alumno aprenderá los fundamentos de los pipelines de GitHub Actions y configurará un pipeline
sencillo para una aplicación Java con Spring Boot y Maven. 

## Parte 1 - CI

```YML
name: Build and test of Java Project
on: [push]
jobs:
 build:
   runs-on: ubuntu-latest  
   steps:
     - uses: actions/checkout@v2
     - name: Set up JDK 1.8
       uses: actions/setup-java@v1
       with:
         java-version: 1.8
     - name: Build with Maven
       run: mvn -B package --file pom.xml
```

## Recursos
https://www.adictosaltrabajo.com/2020/10/28/introduccion-a-github-actions-sintaxis-basica/

[![License: CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC_BY--NC--SA_4.0-lightgrey.svg)](https://creativecommons.org/licenses/by-nc-sa/4.0/)
