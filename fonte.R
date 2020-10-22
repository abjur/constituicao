library(fs)
library(xml2)
library(httr)
library(rlang)
library(jsonlite)
library(lubridate)
library(tidyverse)

# Get CF's full text after each EMC (and EMR)
get_cfs <- function(path) {
  
  # Homepage
  base <- "https://www.senado.leg.br/atividade/const/con1988/"
  
  # Create output table
  out <- "https://www.senado.leg.br/atividade/const/emendas_a.txt" %>%
    read_json() %>%
    pluck(1) %>%
    transpose() %>%
    as_tibble() %>%
    rename(emenda = ementa) %>%
    unnest(everything()) %>%
    mutate(
      data_ = format.Date(data, "%d.%m.%Y"),
      url = str_c(base, "con1988_", data_, "/CON1988.asp")
    ) %>%
    add_row(
      norma = "ORIGINAL",
      data = "1988-10-05",
      data_ = "05.10.1988",
      emenda = "Texto promulgado.",
      url = str_c(base, "CON1988_05.10.1988/CON1988.asp")
    ) %>%
    arrange(data, norma) %>%
    group_by(data) %>%
    summarise(
      norma = str_c(norma, collapse = ", "),
      data = data[1],
      emenda = emenda %>%
        str_c(collapse = "\n\n") %>%
        str_remove("^\\n+$") %>%
        str_replace("(\\n\\n)", "\n\n"),
      data_ = data_[1],
      url = url[1],
      url2 = str_replace_all(url, "(con|CON)1988([_.])", "ADC1988\\2")
    ) %>%
    mutate(
      data_ = str_remove_all(data, "-"),
      url2 = ifelse(norma == "EMC 79", lag(url2), url2), # Fix missing link
      caminho = norma %>%
        str_remove_all(" ") %>%
        str_replace_all(",", "_") %>%
        str_c(data_, "_", .) %>%
        str_c(path, "/", ., ".html")
    )
  
  # Iterate over all CFs (and append ADCTs)
  out %>%
    pull(url) %>%
    map(GET) %>%
    map(read_html, encoding = "ISO-8859-1") %>%
    map(as.character) %>%
    walk2(out$caminho, write_file)
  out %>%
    pull(url2) %>%
    map(GET) %>%
    map(read_html, encoding = "ISO-8859-1") %>%
    map(as.character) %>%
    walk2(out$caminho, write_file, append = TRUE)
  
  return(select(out, -data_, -url, -url2))
}

# Convert a CF file into a table
cf_to_table <- function(file) {
  
  # This side effect-less pipeline does all the work
  file %>%
    
    # Filter HTML into reasonable list
    read_html() %>%
    xml_find_all("//div[@id='conteudoConst']/p") %>%
    map(~list(
      classe = xml_attr(.x, "class"),
      texto = xml_text(.x)
    )) %>%
    
    # Convert into a table
    transpose() %>%
    as_tibble() %>%
    unnest(everything()) %>%
    filter(!is.na(classe)) %>%
    
    # Transform columns
    mutate(
      
      # Make some small adjustments
      texto = str_squish(texto),
      classe = ifelse(classe == "titartb1", "titartb", classe),
      
      # Bind title and subtitle
      texto = ifelse(classe == "titartb", paste0(texto, ": ", lead(texto)), texto),
      
      # Get all numbering for all levels
      titulo = str_extract(texto, "(?<=^Título )[IVX]+"),
      capitulo = str_extract(texto, "(?<=^Capítulo )[IVX]+"),
      secao = str_extract(texto, "(?<=^Seção )[IVX]+"),
      subsecao = str_extract(texto, "(?<=^Subseção )[IVX]+"),
      artigo = str_extract(texto, "(?<=^Art\\. )[0-9A-Z\\-]+"),
      paragrafo = str_extract(texto, "(?<=^§ )[0-9A-Zº\\-]+"),
      paragrafo = ifelse(str_detect(texto, "^Pará"), 1, paragrafo),
      inciso = str_extract(texto, "^[IVXLA-Z\\-]+(?= -)"),
      inciso = ifelse(inciso == "VIX", "IX", inciso), # Fix spelling error
      alinea = str_extract(texto, "^[a-z]+(?=\\))"),
      
      # Convert formats
      titulo = as.numeric(as.roman(titulo)),
      capitulo = as.numeric(as.roman(capitulo)),
      secao = as.numeric(as.roman(secao)),
      subsecao = as.numeric(as.roman(subsecao)),
      paragrafo = str_remove_all(paragrafo, "[^0-9A-Z\\-]+"),
      inciso = str_replace(
        inciso, "[IVXL]+",
        as.character(as.numeric(as.roman(str_extract(inciso, "[IVXL]+"))))
      ),
      alinea = match(alinea, letters),
      
      # Add ADCT as last chapter
      titulo = ifelse(
        classe == "ementa" & str_detect(texto, "Ato"),
        max(titulo, na.rm = TRUE)+1, titulo
      ),
      classe = ifelse(
        classe == "ementa" & str_detect(texto, "Ato"),
        "titartb", classe
      )
    ) %>%
    
    # Filter excess
    filter(classe != "subt", classe != "subt1") %>%
    filter(!classe %in% c("parteFinal", "ementa", "preambulo")) %>% 
    
    # Fill subelements of each title/chapter/...
    fill(titulo) %>%
    group_by(titulo) %>%
    fill(capitulo) %>%
    group_by(titulo, capitulo) %>%
    fill(secao) %>%
    group_by(titulo, capitulo, secao) %>%
    fill(subsecao) %>%
    group_by(titulo, capitulo, secao, subsecao) %>%
    fill(artigo) %>%
    group_by(titulo, capitulo, secao, subsecao, artigo) %>%
    fill(paragrafo) %>%
    group_by(titulo, capitulo, secao, subsecao, artigo) %>%
    mutate(inciso = ifelse(classe == "paragrafo", "0", inciso)) %>%
    fill(inciso) %>%
    mutate(inciso = ifelse(inciso == "0", NA_character_, inciso)) %>%
    ungroup()
}

# Convert a CF table into a list
table_to_list <- function(file) {
  
  # Add line of CF table to root list
  add_line <- function(root, line) {
    
    # Discard empty columns
    line <- discard(line, is.na)
    
    # Build list for current line
    entry <- list(
      classe = names(line)[length(line)],
      numero = line[[length(line)]],
      texto = line[["texto"]]
    )
    
    # Create expression that indexed current list
    expr <- line %>%
      magrittr::extract(-c(1, 2)) %>%
      set_names(~paste0(str_replace(.x, "secao", "secoe"), "s")) %>%
      imap(~list(.y, as.character(.x))) %>%
      set_names(NULL) %>%
      flatten() %>%
      flatten_chr() %>%
      str_c(collapse = "']][['") %>%
      str_c("[['", ., "']]") %>%
      str_c("root", ., " <- entry")
    
    # Eval expression, inserting line in the correct place
    eval_bare(parse_expr(expr))
    
    return(root)
  }
  
  # Apply add_line() to each line of the table
  file %>%
    read_csv(col_types = cols(.default = "c")) %>%
    transpose() %>%
    reduce(add_line, .init = list())
}

# Convert CF table to markdown
table_to_md <- function(file) {
  
  # Convert text in table to markdown
  file %>%
    read_csv(col_types = cols(.default = "c")) %>%
    rowwise() %>%
    mutate(
      
      # Header octothorpes
      header = all(is.na(c_across(artigo:alinea))),
      level = sum(!is.na(c_across(titulo:subsecao))),
      level = paste0(rep("#", level+1), collapse = ""),
      texto = ifelse(header, paste(level, texto), texto),
      
      # Bold and italics
      texto = str_replace(texto, "^(Art\\. [0-9A-Z\\-]+º?\\.?)", "**\\1**"),
      texto = str_replace(texto, "^(§ [0-9A-Z\\-º\\.]+)", "**\\1**"),
      texto = str_replace(texto, "^(Parágrafo único\\.)", "**\\1**"),
      texto = str_replace(texto, "^([a-z]+\\))", "_\\1_"),
      
      # Text indentations
      level = ifelse(!is.na(artigo), "", NA_character_),
      level = ifelse(!is.na(paragrafo), " ", level),
      level = ifelse(!is.na(inciso), "  ", level),
      level = ifelse(!is.na(alinea), "    ", level),
      texto = ifelse(!header, paste0(level, texto), texto)
    ) %>%
    ungroup() %>%
    pull(texto) %>%
    
    # Prepend preamble and title
    prepend(paste(
      "# Constituição da República Federativa do Brasil\n\n",
      "**Preâmbulo**\n\nNós, representantes do povo brasileiro, reunidos em",
      "Assembléia Nacional Constituinte para instituir um Estado Democrático,",
      "destinado a assegurar o exercício dos direitos sociais e individuais, a",
      "liberdade, a segurança, o bem-estar, o desenvolvimento, a igualdade e a",
      "justiça como valores supremos de uma sociedade fraterna, pluralista e",
      "sem preconceitos, fundada na harmonia social e comprometida, na ordem",
      "interna e internacional, com a solução pacífica das controvérsias,",
      "promulgamos, sob a proteção de Deus, a seguinte CONSTITUIÇÃO DA",
      "REPÚBLICA FEDERATIVA DO BRASIL."
    )) %>%
    
    # Append date and authors
    append(paste(
      "Brasília, 5 de outubro de 1988.\n\n",
      "Ulysses Guimarães, Presidente - Mauro Benevides , 1.º Vice-Presidente -",
      "Jorge Arbage , 2.º Vice-Presidente - Marcelo Cordeiro , 1.º Secretário -",
      "Mário Maia , 2.º Secretário - Arnaldo Faria de Sá , 3.º Secretário -",
      "Benedita da Silva , 1.º Suplente de Secretário - Luiz Soyer , 2.º",
      "Suplente de Secretário - Sotero Cunha , 3.º Suplente de Secretário -",
      "Bernardo Cabral , Relator Geral - Adolfo Oliveira , Relator Adjunto -",
      "Antônio Carlos Konder Reis , Relator Adjunto - José Fogaça , Relator",
      "Adjunto - Abigail Feitosa - Acival Gomes - Adauto Pereira - Ademir",
      "Andrade - Adhemar de Barros Filho - Adroaldo Streck - Adylson Motta -",
      "Aécio de Borba - Aécio Neves - Affonso Camargo - Afif Domingos - Afonso",
      "Arinos - Afonso Sancho - Agassiz Almeida - Agripino de Oliveira Lima -",
      "Airton Cordeiro - Airton Sandoval - Alarico Abib - Albano Franco -",
      "Albérico Cordeiro - Albérico Filho - Alceni Guerra - Alcides Saldanha -",
      "Aldo Arantes - Alércio Dias - Alexandre Costa - Alexandre Puzyna -",
      "Alfredo Campos - Almir Gabriel - Aloisio Vasconcelos - Aloysio Chaves -",
      "Aloysio Teixeira - Aluizio Bezerra - Aluízio Campos - Álvaro Antônio -",
      "Álvaro Pacheco - Álvaro Valle - Alysson Paulinelli - Amaral Netto -",
      "Amaury Müller - Amilcar Moreira - Ângelo Magalhães - Anna Maria Rattes",
      "- Annibal Barcellos - Antero de Barros - Antônio Câmara - Antônio Carlos",
      "Franco - Antonio Carlos Mendes Thame - Antônio de Jesus - Antonio",
      "Ferreira - Antonio Gaspar - Antonio Mariz - Antonio Perosa - Antônio",
      "Salim Curiati - Antonio Ueno - Arnaldo Martins - Arnaldo Moraes -",
      "Arnaldo Prieto - Arnold Fioravante - Arolde de Oliveira - Artenir Werner",
      "- Artur da Távola - Asdrubal Bentes - Assis Canuto - Átila Lira -",
      "Augusto Carvalho - Áureo Mello - Basílio Villani - Benedicto Monteiro -",
      "Benito Gama - Beth Azize - Bezerra de Melo - Bocayuva Cunha - Bonifácio",
      "de Andrada - Bosco França - Brandão Monteiro - Caio Pompeu - Carlos",
      "Alberto - Carlos Alberto Caó - Carlos Benevides - Carlos Cardinal -",
      "Carlos Chiarelli - Carlos Cotta - Carlos De'Carli - Carlos Mosconi -",
      "Carlos Sant'Anna - Carlos Vinagre - Carlos Virgílio - Carrel Benevides -",
      "Cássio Cunha Lima - Célio de Castro - Celso Dourado - César Cals Neto -",
      "César Maia - Chagas Duarte - Chagas Neto - Chagas Rodrigues - Chico",
      "Humberto - Christóvam Chiaradia - Cid Carvalho - Cid Sabóia de Carvalho",
      "- Cláudio Ávila - Cleonâncio Fonseca - Costa Ferreira - Cristina Tavares",
      "- Cunha Bueno - Dálton Canabrava - Darcy Deitos - Darcy Pozza - Daso",
      "Coimbra - Davi Alves Silva - Del Bosco Amaral - Delfim Netto - Délio",
      "Braz - Denisar Arneiro - Dionisio Dal Prá - Dionísio Hage - Dirce Tutu",
      "Quadros - Dirceu Carneiro - Divaldo Suruagy - Djenal Gonçalves -",
      "Domingos Juvenil - Domingos Leonelli - Doreto Campanari - Edésio Frias -",
      "Edison Lobão - Edivaldo Motta - Edme Tavares - Edmilson Valentim -",
      "Eduardo Bonfim - Eduardo Jorge - Eduardo Moreira - Egídio Ferreira Lima",
      "- Elias Murad - Eliel Rodrigues - Eliézer Moreira - Enoc Vieira - Eraldo",
      "Tinoco - Eraldo Trindade - Erico Pegoraro - Ervin Bonkoski - Etevaldo",
      "Nogueira - Euclides Scalco - Eunice Michiles - Evaldo Gonçalves -",
      "Expedito Machado - Ézio Ferreira - Fábio Feldmann - Fábio Raunheitti -",
      "Farabulini Júnior - Fausto Fernandes - Fausto Rocha - Felipe Mendes -",
      "Feres Nader - Fernando Bezerra Coelho - Fernando Cunha - Fernando",
      "Gasparian - Fernando Gomes - Fernando Henrique Cardoso - Fernando Lyra",
      "- Fernando Santana - Fernando Velasco - Firmo de Castro - Flavio Palmier",
      "da Veiga - Flávio Rocha - Florestan Fernandes - Floriceno Paixão -",
      "França Teixeira - Francisco Amaral - Francisco Benjamim - Francisco",
      "Carneiro - Francisco Coelho - Francisco Diógenes - Francisco Dornelles",
      "- Francisco Küster - Francisco Pinto - Francisco Rollemberg - Francisco",
      "Rossi - Francisco Sales - Furtado Leite - Gabriel Guerreiro - Gandi",
      "Jamil - Gastone Righi - Genebaldo Correia - Genésio Bernardino - Geovani",
      "Borges - Geraldo Alckmin Filho - Geraldo Bulhões - Geraldo Campos -",
      "Geraldo Fleming - Geraldo Melo - Gerson Camata - Gerson Marcondes -",
      "Gerson Peres - Gidel Dantas - Gil César - Gilson Machado - Gonzaga",
      "Patriota - Guilherme Palmeira - Gumercindo Milhomem - Gustavo de Faria -",
      "Harlan Gadelha - Haroldo Lima - Haroldo Sabóia - Hélio Costa - Hélio",
      "Duque - Hélio Manhães - Hélio Rosas - Henrique Córdova - Henrique Eduardo",
      "Alves - Heráclito Fortes - Hermes Zaneti - Hilário Braun - Homero Santos",
      "- Humberto Lucena - Humberto Souto - Iberê Ferreira - Ibsen Pinheiro -",
      "Inocêncio Oliveira - Irajá Rodrigues - Iram Saraiva - Irapuan Costa",
      "Júnior - Irma Passoni - Ismael Wanderley - Israel Pinheiro - Itamar",
      "Franco - Ivo Cersósimo - Ivo Lech - Ivo Mainardi - Ivo Vanderlinde - Jacy",
      "Scanagatta - Jairo Azi - Jairo Carneiro - Jalles Fontoura - Jamil Haddad",
      "- Jarbas Passarinho - Jayme Paliarin - Jayme Santana - Jesualdo",
      "Cavalcanti - Jesus Tajra - Joaci Góes - João Agripino - João Alves - João",
      "Calmon - João Carlos Bacelar - João Castelo - João Cunha - João da Mata",
      "- João de Deus Antunes - João Herrmann Neto - João Lobo - João Machado",
      "Rollemberg - João Menezes - João Natal - João Paulo - João Rezek -",
      "Joaquim Bevilácqua - Joaquim Francisco - Joaquim Hayckel - Joaquim Sucena",
      "- Jofran Frejat - Jonas Pinheiro - Jonival Lucas - Jorge Bornhausen -",
      "Jorge Hage - Jorge Leite - Jorge Uequed - Jorge Vianna - José Agripino -",
      "José Camargo - José Carlos Coutinho - José Carlos Grecco - José Carlos",
      "Martinez - José Carlos Sabóia - José Carlos Vasconcelos - José Costa -",
      "José da Conceição - José Dutra - José Egreja - José Elias - José",
      "Fernandes - José Freire - José Genoíno - José Geraldo - José Guedes -",
      "José Ignácio Ferreira - José Jorge - José Lins - José Lourenço - José",
      "Luiz de Sá - José Luiz Maia - José Maranhão - José Maria Eymael - José",
      "Maurício - José Melo - José Mendonça Bezerra - José Moura - José Paulo",
      "Bisol - José Queiroz - José Richa - José Santana de Vasconcellos - José",
      "Serra - José Tavares - José Teixeira - José Thomaz Nonô - José Tinoco -",
      "José Ulísses de Oliveira - José Viana - José Yunes - Jovanni Masini -",
      "Juarez Antunes - Júlio Campos - Júlio Costamilan - Jutahy Júnior - Jutahy",
      "Magalhães - Koyu Iha - Lael Varella - Lavoisier Maia - Leite Chaves -",
      "Lélio Souza - Leopoldo Peres - Leur Lomanto - Levy Dias - Lézio Sathler -",
      "Lídice da Mata - Louremberg Nunes Rocha - Lourival Baptista - Lúcia Braga",
      "- Lúcia Vânia - Lúcio Alcântara - Luís Eduardo - Luís Roberto Ponte -",
      "Luiz Alberto Rodrigues - Luiz Freire - Luiz Gushiken - Luiz Henrique -",
      "Luiz Inácio Lula da Silva - Luiz Leal - Luiz Marques - Luiz Salomão -",
      "Luiz Viana - Luiz Viana Neto - Lysâneas Maciel - Maguito Vilela - Maluly",
      "Neto - Manoel Castro - Manoel Moreira - Manoel Ribeiro - Mansueto de",
      "Lavor - Manuel Viana - Márcia Kubitschek - Márcio Braga - Márcio Lacerda",
      "- Marco Maciel - Marcondes Gadelha - Marcos Lima - Marcos Queiroz - Maria",
      "de Lourdes Abadia - Maria Lúcia - Mário Assad - Mário Covas - Mário de",
      "Oliveira - Mário Lima - Marluce Pinto - Matheus Iensen - Mattos Leão -",
      "Maurício Campos - Maurício Correa - Maurício Fruet - Maurício Nasser -",
      "Maurício Pádua - Maurílio Ferreira Lima - Mauro Borges - Mauro Campos -",
      "Mauro Miranda - Mauro Sampaio - Max Rosenmann - Meira Filho - Melo Freire",
      "- Mello Reis - Mendes Botelho - Mendes Canale - Mendes Ribeiro - Messias",
      "Góis - Messias Soares - Michel Temer - Milton Barbosa - Milton Lima -",
      "Milton Reis - Miraldo Gomes - Miro Teixeira - Moema São Thiago - Moysés",
      "Pimentel - Mozarildo Cavalcanti - Mussa Demes - Myrian Portella - Nabor",
      "Júnior - Naphtali Alves de Souza - Narciso Mendes - Nelson Aguiar -",
      "Nelson Carneiro - Nelson Jobim - Nelson Sabrá - Nelson Seixas - Nelson",
      "Wedekin - Nelton Friedrich - Nestor Duarte - Ney Maranhão - Nilso",
      "Sguarezi - Nilson Gibson - Nion Albernaz - Noel de Carvalho - Nyder",
      "Barbosa - Octávio Elísio - Odacir Soares - Olavo Pires - Olívio Dutra -",
      "Onofre Corrêa - Orlando Bezerra - Orlando Pacheco - Oscar Corrêa - Osmar",
      "Leitão - Osmir Lima - Osmundo Rebouças - Osvaldo Bender - Osvaldo Coelho",
      "- Osvaldo Macedo - Osvaldo Sobrinho - Oswaldo Almeida - Oswaldo Trevisan",
      "- Ottomar Pinto - Paes de Andrade - Paes Landim - Paulo Delgado - Paulo",
      "Macarini - Paulo Marques - Paulo Mincarone - Paulo Paim - Paulo Pimentel",
      "- Paulo Ramos - Paulo Roberto - Paulo Roberto Cunha - Paulo Silva - Paulo",
      "Zarzur - Pedro Canedo - Pedro Ceolin - Percival Muniz - Pimenta da Veiga",
      "- Plínio Arruda Sampaio - Plínio Martins - Pompeu de Sousa - Rachid",
      "Saldanha Derzi - Raimundo Bezerra - Raimundo Lira - Raimundo Rezende -",
      "Raquel Cândido - Raquel Capiberibe - Raul Belém - Raul Ferraz - Renan",
      "Calheiros - Renato Bernardi - Renato Johnsson - Renato Vianna - Ricardo",
      "Fiuza - Ricardo Izar - Rita Camata - Rita Furtado - Roberto Augusto -",
      "Roberto Balestra - Roberto Brant - Roberto Campos - Roberto D'Ávila -",
      "Roberto Freire - Roberto Jefferson - Roberto Rollemberg - Roberto Torres",
      "- Roberto Vital - Robson Marinho - Rodrigues Palma - Ronaldo Aragão -",
      "Ronaldo Carvalho - Ronaldo Cezar Coelho - Ronan Tito - Ronaro Corrêa -",
      "Rosa Prata - Rose de Freitas - Rospide Netto - Rubem Branquinho - Rubem",
      "Medina - Ruben Figueiró - Ruberval Pilotto - Ruy Bacelar - Ruy Nedel -",
      "Sadie Hauache - Salatiel Carvalho - Samir Achôa - Sandra Cavalcanti -",
      "Santinho Furtado - Sarney Filho - Saulo Queiroz - Sérgio Brito - Sérgio",
      "Spada - Sérgio Werneck - Severo Gomes - Sigmaringa Seixas - Sílvio Abreu",
      "- Simão Sessim - Siqueira Campos - Sólon Borges dos Reis - Stélio Dias -",
      "Tadeu França - Telmo Kirst - Teotonio Vilela Filho - Theodoro Mendes -",
      "Tito Costa - Ubiratan Aguiar - Ubiratan Spinelli - Uldurico Pinto -",
      "Valmir Campelo - Valter Pereira - Vasco Alves - Vicente Bogo - Victor",
      "Faccioni - Victor Fontana - Victor Trovão - Vieira da Silva - Vilson",
      "Souza - Vingt Rosado - Vinicius Cansanção - Virgildásio de Senna -",
      "Virgílio Galassi - Virgílio Guimarães - Vitor Buaiz - Vivaldo Barbosa -",
      "Vladimir Palmeira - Wagner Lago - Waldec Ornélas - Waldyr Pugliesi -",
      "Walmor de Luca - Wilma Maia - Wilson Campos - Wilson Martins - Ziza",
      "Valadares.\n\n",
      "PARTICIPANTES: Álvaro Dias - Antônio Britto - Bete Mendes - Borges da",
      "Silveira - Cardoso Alves - Edivaldo Holanda - Expedito Júnior - Fadah",
      "Gattass - Francisco Dias - Geovah Amarante - Hélio Gueiros - Horácio",
      "Ferraz - Hugo Napoleão - Iturival Nascimento - Ivan Bonato - Jorge",
      "Medauar - José Mendonça de Morais - Leopoldo Bessone - Marcelo Miranda -",
      "Mauro Fecury - Neuto de Conto - Nivaldo Machado - Oswaldo Lima Filho -",
      "Paulo Almada - Prisco Viana - Ralph Biasi - Rosário Congro Neto - Sérgio",
      "Naya - Tidei de Lima.\n\n",
      "IN MEMORIAM: Alair Ferreira - Antônio Farias - Fábio Lucena - Norberto",
      "Schwantes - Virgílio Távora."
    )) %>%
    str_c(collapse = "\n\n")
}

# Given a CSV file, commit it and change its date
commit_readme <- function(file, message, description) {
  
  # Convert date to universal format
  date <- file %>%
    path_file() %>%
    str_extract("[0-9]+") %>%
    ymd()
  
  # Write MD to README
  write_file(table_to_md(file), "CONSTITUICAO.md")
  
  # Run commands
  system("git add CONSTITUICAO.md")
  system(str_c(
    'GIT_COMMITTER_DATE="', date, 'T12:00:00" ', 'git commit --allow-empty -m "',
    message, '" -m "', description, '" --date="', date, 'T12:00:00"'
  ))
}

# Create paths
dir_create("HTML/")
dir_create("CSV/")
dir_create("JSON/")

# Download source HTMLs
df <- get_cfs("HTML/")

# Convert HTML to table
"HTML/" %>%
  dir_ls() %>%
  as.character() %>%
  set_names(~str_replace(str_replace(.x, "html", "csv"), "HTML", "CSV")) %>%
  map(cf_to_table) %>%
  imap(write_csv)

# Convert CSV to JSON
"CSV/" %>%
  dir_ls() %>%
  as.character() %>%
  set_names(~str_replace(str_replace(.x, "csv", "json"), "CSV", "JSON")) %>%
  map(table_to_list) %>%
  imap(write_json)

# Write MDs to README and commit them
inputs <- df %>%
  mutate(
    caminho = str_replace(caminho, "HTML", "CSV"),
    caminho = str_replace(caminho, "html", "csv")
  ) %>%
  select(file = caminho, message = norma, description = emenda)

for (i in seq_len(nrow(inputs))) {
  message(i)
  commit_readme(inputs$file[i], inputs$message[i], inputs$description[i])
}

# git rev-list --max-parents=0 --abbrev-commit HEAD
# git reset --hard 3f50914
# git push --force
