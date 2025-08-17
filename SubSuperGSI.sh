#!/bin/bash

# Script para trocar as system.img presente na super.img por uma imagem GSI, no Termux
# Autor: Vinícius
# Versão: 1.1 - Otimizado e Validado

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem Cor

# Função para imprimir com cores
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Função para obter tamanho do arquivo em bytes
get_file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null
}

# Função para verificar espaço disponível
check_space() {
    local required_space=$1
    local available_space=$(df "$PWD" | tail -1 | awk '{print $4}')
    available_space=$((available_space * 1024)) # Converter para bytes
    
    if [ $required_space -gt $available_space ]; then
        print_error "Espaço insuficiente!"
        print_error "Necessário: $(echo $required_space | numfmt --to=iec --format="%.1f")"
        print_error "Disponível: $(echo $available_space | numfmt --to=iec --format="%.1f")"
        return 1
    fi
    return 0
}

# Função para verificar se um arquivo existe
check_file() {
    if [ ! -f "$1" ]; then
        print_error "Arquivo não encontrado: $1"
        print_status "Caminho absoluto tentado: $(realpath "$1" 2>/dev/null || echo "Não foi possível resolver o caminho")"
        exit 1
    else
        print_success "Arquivo encontrado: $1"
        print_status "Tamanho: $(ls -lh "$1" | awk '{print $5}')"
    fi
}

# Função para validar GSI
validate_gsi() {
    local gsi_path="$1"
    
    print_status "Validando GSI (Generic System Image)..."
    
    # Verificar tamanho mínimo (GSI deve ter pelo menos 1GB)
    local gsi_size=$(get_file_size "$gsi_path")
    local min_size=$((1024 * 1024 * 1024)) # 1GB
    
    if [ $gsi_size -lt $min_size ]; then
        print_warning "GSI parece muito pequena (< 1GB)"
        print_warning "Tamanho atual: $(echo $gsi_size | numfmt --to=iec --format="%.1f")"
        return 2
    fi
    
    # Verificar tipo de arquivo
    local file_type=$(file "$gsi_path")
    print_status "Tipo da GSI: $file_type"
    
    if echo "$file_type" | grep -q -E "(ext[2-4]|Android sparse)"; then
        print_success "GSI tem formato filesystem válido"
        return 0
    else
        print_warning "GSI pode não ter formato filesystem reconhecido"
        print_warning "Continuando mesmo assim..."
        return 2
    fi
}

# Função para verificar formato e integridade do super.img
validate_super_img() {
    local img_path="$1"
    local img_name="$2"
    
    print_status "Validando $img_name..."
    
    # Verificar se o arquivo existe e não está vazio
    if [ ! -f "$img_path" ] || [ ! -s "$img_path" ]; then
        print_error "$img_name não existe ou está vazio"
        return 1
    fi
    
    # Obter informações básicas
    local file_size=$(get_file_size "$img_path")
    local file_type=$(file "$img_path")
    
    print_status "Tamanho: $(echo $file_size | numfmt --to=iec --format="%.1f")"
    print_status "Tipo detectado: $file_type"
    
    # Verificar se é um arquivo Android válido
    if ! echo "$file_type" | grep -q -E "(Android sparse|data)"; then
        print_warning "$img_name não parece ser um arquivo Android válido"
        print_warning "Tipo detectado: $file_type"
        return 2
    fi
    
    # Tentar verificar estrutura da super partition com lpunpack
    print_status "Verificando estrutura interna da super partition..."
    local temp_check_dir=$(mktemp -d)
    
    # Preparar arquivo para teste
    local test_file="$img_path"
    if echo "$file_type" | grep -q "Android sparse"; then
        print_status "Convertendo sparse para raw para verificação..."
        if ! simg2img "$img_path" "$temp_check_dir/test_super.img" 2>/dev/null; then
            print_error "Falha ao converter arquivo sparse para verificação"
            rm -rf "$temp_check_dir"
            return 1
        fi
        test_file="$temp_check_dir/test_super.img"
    fi
    
    # Testar lpunpack (apenas listar, não extrair)
    if lpunpack "$test_file" "$temp_check_dir/test_extract/" >/dev/null 2>&1; then
        print_success "$img_name tem estrutura super partition válida"
        
        # Listar partições encontradas
        local partitions=$(ls "$temp_check_dir/test_extract/" 2>/dev/null | grep "\.img$" | wc -l)
        print_status "Partições encontradas: $partitions"
        
        # Verificar partições críticas
        if [ -f "$temp_check_dir/test_extract/system.img" ]; then
            local sys_size=$(get_file_size "$temp_check_dir/test_extract/system.img")
            print_status "System partition: $(echo $sys_size | numfmt --to=iec --format="%.1f")"
        else
            print_error "Partição system não encontrada em $img_name!"
            rm -rf "$temp_check_dir"
            return 1
        fi
        
        # Verificar outras partições importantes
        for part in vendor product odm system_ext; do
            if [ -f "$temp_check_dir/test_extract/${part}.img" ]; then
                local part_size=$(get_file_size "$temp_check_dir/test_extract/${part}.img")
                print_status "${part^} partition: $(echo $part_size | numfmt --to=iec --format="%.1f")"
            fi
        done
        
    else
        print_error "$img_name não tem estrutura super partition válida"
        print_error "Não pode ser processada com lpunpack"
        rm -rf "$temp_check_dir"
        return 1
    fi
    
    # Limpeza
    rm -rf "$temp_check_dir"
    
    print_success "$img_name passou na validação ✓"
    return 0
}

# Função para verificar dependências
check_dependencies() {
    print_status "Verificando dependências..."
    
    # Lista de ferramentas necessárias
    tools=("lpunpack" "lpmake" "simg2img" "img2simg" "tar" "gzip")
    
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            print_error "$tool não está instalado"
            print_status "Instale com: pkg install android-tools"
            exit 1
        fi
    done
    
    print_success "Todas as dependências estão instaladas"
}

# Função principal
main() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    Script de Modificação Super.img${NC}"
    echo -e "${BLUE}    Para Termux - GSI Replacement${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo

    # Verificar dependências
    check_dependencies
    echo

    # Solicitar caminhos dos arquivos
    print_status "Por favor, forneça os caminhos dos arquivos necessários:"
    print_status "Dica: Use caminhos absolutos (que começam com /) ou relativos ao diretório atual"
    echo

    read -p "Caminho para o arquivo super.img: " SUPER_IMG
    # Expandir ~ se presente
    SUPER_IMG="${SUPER_IMG/#\~/$HOME}"
    
    # Converter para caminho absoluto ANTES de mudar de diretório
    SUPER_IMG_ABS=$(realpath "$SUPER_IMG")
    check_file "$SUPER_IMG_ABS"

    read -p "Caminho para a GSI (system.img): " GSI_IMG
    # Expandir ~ se presente  
    GSI_IMG="${GSI_IMG/#\~/$HOME}"
    
    # Converter para caminho absoluto ANTES de mudar de diretório
    GSI_IMG_ABS=$(realpath "$GSI_IMG")
    check_file "$GSI_IMG_ABS"
    
    echo
    print_status "🔍 VALIDAÇÃO DE INTEGRIDADE DOS ARQUIVOS"
    print_status "================================================"
    
    # Validar super.img original
    if ! validate_super_img "$SUPER_IMG_ABS" "Super.img original"; then
        print_error "Super.img original não passou na validação!"
        print_error "Verifique se o arquivo está correto e não corrompido"
        exit 1
    fi
    
    echo
    # Validar GSI
    if ! validate_gsi "$GSI_IMG_ABS"; then
        print_warning "GSI apresentou warnings na validação"
        read -p "Continuar mesmo assim? (y/N): " continue_gsi
        if [[ ! $continue_gsi =~ ^[Yy]$ ]]; then
            print_status "Operação cancelada pelo usuário"
            exit 1
        fi
    fi
    
    echo
    print_success "✅ Validação inicial concluída com sucesso!"
    echo

    read -p "Diretório de trabalho (será criado se não existir): " WORK_DIR
    # Expandir ~ se presente
    WORK_DIR="${WORK_DIR/#\~/$HOME}"
    read -p "Nome do arquivo final (ex: super_modified): " OUTPUT_NAME

    # Criar diretório de trabalho
    print_status "Criando diretório de trabalho: $WORK_DIR"
    mkdir -p "$WORK_DIR"
    if [ $? -ne 0 ]; then
        print_error "Não foi possível criar o diretório: $WORK_DIR"
        exit 1
    fi
    
    cd "$WORK_DIR" || exit 1
    print_status "Diretório atual: $(pwd)"
    
    # Verificar espaço disponível estimado
    SUPER_SIZE_EST=$(get_file_size "$SUPER_IMG_ABS")
    GSI_SIZE=$(get_file_size "$GSI_IMG_ABS")
    REQUIRED_SPACE=$((SUPER_SIZE_EST + GSI_SIZE)) # Estimativa conservadora
    
    print_status "Verificando espaço disponível..."
    print_status "Espaço estimado necessário: $(echo $REQUIRED_SPACE | numfmt --to=iec --format="%.1f")"
    
    if ! check_space $REQUIRED_SPACE; then
        print_warning "Considere usar um diretório com mais espaço livre"
        read -p "Continuar mesmo assim? (y/N): " continue_anyway
        if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    print_status "Iniciando processo de modificação..."
    echo

    # Passo 1: Preparar arquivos de trabalho
    print_status "Passo 1: Preparando arquivos de trabalho..."
    
    print_status "Super.img source: $SUPER_IMG_ABS"
    print_status "GSI source: $GSI_IMG_ABS"
    
    # Limpar apenas arquivos temporários específicos
    print_status "Limpando arquivos temporários antigos..."
    rm -rf extracted/ super_raw.img odin_package/ *.tar* 2>/dev/null
    
    # Remover apenas arquivos temporários .img, preservando originais
    for temp_img in *_super.img *_modified.img temp_*.img work_*.img; do
        [ -f "$temp_img" ] && rm -f "$temp_img"
    done
    
    # Processar super.img - usar referência direta se possível
    if file "$SUPER_IMG_ABS" | grep -q "Android sparse image"; then
        print_status "Super.img está em formato sparse, convertendo para raw..."
        simg2img "$SUPER_IMG_ABS" super_raw.img
        if [ $? -ne 0 ]; then
            print_error "Falha ao converter sparse para raw"
            exit 1
        fi
        SUPER_RAW="$(pwd)/super_raw.img"
    else
        print_status "Super.img já está em formato raw"
        # Usar diretamente o arquivo original para economizar espaço
        SUPER_RAW="$SUPER_IMG_ABS"
    fi
    
    print_success "Arquivo de trabalho preparado"
    print_status "Usando: $SUPER_RAW"

    # Verificar se os arquivos ainda existem após mudança de diretório
    print_status "Validando caminhos dos arquivos..."
    if [ ! -f "$SUPER_IMG_ABS" ]; then
        print_error "Super.img não encontrada: $SUPER_IMG_ABS"
        exit 1
    fi
    if [ ! -f "$GSI_IMG_ABS" ]; then
        print_error "GSI não encontrada: $GSI_IMG_ABS" 
        exit 1
    fi
    print_success "Arquivos validados"

    # Passo 2: Extrair partições com lpunpack
    print_status "Passo 2: Extraindo partições da super.img..."
    mkdir -p extracted
    
    print_status "Executando: lpunpack $SUPER_RAW extracted/"
    lpunpack "$SUPER_RAW" extracted/

    if [ $? -ne 0 ]; then
        print_error "Falha ao extrair partições"
        exit 1
    fi

    print_success "Partições extraídas com sucesso"
    ls -la extracted/

    # Passo 3: Substituir system.img pela GSI
    print_status "Passo 3: Substituindo system.img pela GSI..."
    
    # Remover system.img original
    rm -f extracted/system.img
    
    # Processar GSI - usar referência direta se possível
    if file "$GSI_IMG_ABS" | grep -q "Android sparse image"; then
        print_status "GSI está em formato sparse, convertendo para raw..."
        simg2img "$GSI_IMG_ABS" extracted/system.img
        if [ $? -ne 0 ]; then
            print_error "Falha ao converter GSI de sparse para raw"
            exit 1
        fi
    else
        print_status "GSI já está em formato raw, copiando..."
        cp "$GSI_IMG_ABS" extracted/system.img
        if [ $? -ne 0 ]; then
            print_error "Falha ao copiar GSI"
            exit 1
        fi
    fi

    print_success "System.img substituída pela GSI"
    print_status "Novo tamanho: $(ls -lh extracted/system.img | awk '{print $5}')"

    # Passo 4: Calcular tamanhos e validar partições
    print_status "Passo 4: Analisando partições extraídas..."
    
    # Listar partições encontradas
    print_status "Partições encontradas:"
    ls -lah extracted/
    
    # Calcular tamanhos das partições existentes
    SYSTEM_SIZE=$(get_file_size "extracted/system.img")
    
    # Verificar partições opcionais
    VENDOR_SIZE=0
    PRODUCT_SIZE=0
    ODM_SIZE=0
    SYSTEM_EXT_SIZE=0
    
    [ -f "extracted/vendor.img" ] && VENDOR_SIZE=$(get_file_size "extracted/vendor.img")
    [ -f "extracted/product.img" ] && PRODUCT_SIZE=$(get_file_size "extracted/product.img")
    [ -f "extracted/odm.img" ] && ODM_SIZE=$(get_file_size "extracted/odm.img")
    [ -f "extracted/system_ext.img" ] && SYSTEM_EXT_SIZE=$(get_file_size "extracted/system_ext.img")

    print_status "Tamanhos das partições:"
    print_status "- System: $(echo $SYSTEM_SIZE | numfmt --to=iec --format="%.1f")"
    [ $VENDOR_SIZE -gt 0 ] && print_status "- Vendor: $(echo $VENDOR_SIZE | numfmt --to=iec --format="%.1f")"
    [ $PRODUCT_SIZE -gt 0 ] && print_status "- Product: $(echo $PRODUCT_SIZE | numfmt --to=iec --format="%.1f")"
    [ $ODM_SIZE -gt 0 ] && print_status "- ODM: $(echo $ODM_SIZE | numfmt --to=iec --format="%.1f")"
    [ $SYSTEM_EXT_SIZE -gt 0 ] && print_status "- System_ext: $(echo $SYSTEM_EXT_SIZE | numfmt --to=iec --format="%.1f")"

    # Passo 5: Reempacotar com lpmake
    print_status "Passo 5: Reempacotando super.img com lpmake..."
    
    # Calcular tamanho total da super partition
    TOTAL_SIZE=$((SYSTEM_SIZE + VENDOR_SIZE + PRODUCT_SIZE + ODM_SIZE + SYSTEM_EXT_SIZE))
    SUPER_SIZE=$((TOTAL_SIZE + TOTAL_SIZE / 5))  # Adicionar 20% de margem
    
    print_status "Tamanho total calculado: $(echo $SUPER_SIZE | numfmt --to=iec --format="%.1f")"
    
    # Construir comando lpmake dinamicamente
    LPMAKE_CMD="lpmake --metadata-size 65536 --super-name super --metadata-slots 2"
    LPMAKE_CMD="$LPMAKE_CMD --device super:$SUPER_SIZE"
    LPMAKE_CMD="$LPMAKE_CMD --group main:$SUPER_SIZE"
    
    # Adicionar partições existentes
    if [ -f "extracted/system.img" ]; then
        LPMAKE_CMD="$LPMAKE_CMD --partition system:readonly:$SYSTEM_SIZE:main --image system=extracted/system.img"
    fi
    
    if [ -f "extracted/vendor.img" ]; then
        LPMAKE_CMD="$LPMAKE_CMD --partition vendor:readonly:$VENDOR_SIZE:main --image vendor=extracted/vendor.img"
    fi
    
    if [ -f "extracted/product.img" ]; then
        LPMAKE_CMD="$LPMAKE_CMD --partition product:readonly:$PRODUCT_SIZE:main --image product=extracted/product.img"
    fi
    
    if [ -f "extracted/odm.img" ]; then
        LPMAKE_CMD="$LPMAKE_CMD --partition odm:readonly:$ODM_SIZE:main --image odm=extracted/odm.img"
    fi
    
    if [ -f "extracted/system_ext.img" ]; then
        LPMAKE_CMD="$LPMAKE_CMD --partition system_ext:readonly:$SYSTEM_EXT_SIZE:main --image system_ext=extracted/system_ext.img"
    fi
    
    LPMAKE_CMD="$LPMAKE_CMD --sparse --output ${OUTPUT_NAME}_super.img"
    
    print_status "Executando lpmake..."
    print_status "Comando: $LPMAKE_CMD"
    print_warning "Nota: Warnings sobre 'Invalid sparse file format' são normais e podem ser ignorados"
    
    # Executar lpmake e capturar apenas erros críticos
    eval $LPMAKE_CMD 2>&1 | grep -v "Invalid sparse file format" || true
    
    # Verificar se o arquivo foi criado com sucesso
    if [ ! -f "${OUTPUT_NAME}_super.img" ]; then
        print_error "Falha ao criar nova super.img - tentando sem --sparse..."
        LPMAKE_CMD="${LPMAKE_CMD/--sparse/}"
        print_status "Tentativa sem sparse: $LPMAKE_CMD"
        eval $LPMAKE_CMD 2>&1 | grep -v "Invalid sparse file format" || true
        
        if [ ! -f "${OUTPUT_NAME}_super.img" ]; then
            print_error "Falha definitiva ao criar super.img"
            exit 1
        fi
    fi

    print_success "Nova super.img criada: ${OUTPUT_NAME}_super.img"
    print_status "Tamanho final: $(ls -lh ${OUTPUT_NAME}_super.img | awk '{print $5}')"
    
    echo
    print_status "🔍 VALIDAÇÃO FINAL DO ARQUIVO MODIFICADO"
    print_status "================================================"
    
    # Validar super.img modificada
    if ! validate_super_img "$(pwd)/${OUTPUT_NAME}_super.img" "Super.img modificada"; then
        print_error "Super.img modificada falhou na validação!"
        print_error "O arquivo pode estar corrompido ou mal formado"
        
        # Tentar diagnóstico
        print_status "Executando diagnóstico..."
        if [ -f "${OUTPUT_NAME}_super.img" ]; then
            print_status "Arquivo existe: $(ls -lh ${OUTPUT_NAME}_super.img)"
            print_status "Tipo: $(file ${OUTPUT_NAME}_super.img)"
        fi
        
        print_warning "Recomenda-se verificar os arquivos de entrada e tentar novamente"
        exit 1
    fi
    
    print_success "✅ Super.img modificada passou em todas as validações!"
    echo

    # Passo 6: Preparar arquivo para Odin
    print_status "Passo 6: Preparando arquivo para Odin..."
    
    # Limpar diretório odin antigo
    rm -rf odin_package/
    mkdir -p odin_package
    
    # Mover super.img para o pacote Odin
    mv "${OUTPUT_NAME}_super.img" odin_package/super.img
    
    # Criar arquivo tar para Odin (formato AP)
    print_status "Criando arquivo TAR para Odin..."
    cd odin_package || exit 1
    tar -cf "../${OUTPUT_NAME}_AP.tar" super.img
    cd .. || exit 1
    
    # Verificar se o TAR foi criado com sucesso
    if [ ! -f "${OUTPUT_NAME}_AP.tar" ]; then
        print_error "Falha ao criar arquivo TAR"
        exit 1
    fi
    
    print_success "Arquivo TAR criado: $(ls -lh ${OUTPUT_NAME}_AP.tar | awk '{print $5}')"
    
    # Gerar hash MD5 e renomear
    if command -v md5sum &> /dev/null; then
        print_status "Gerando hash MD5 e finalizando..."
        MD5_HASH=$(md5sum "${OUTPUT_NAME}_AP.tar" | awk '{print $1}')
        mv "${OUTPUT_NAME}_AP.tar" "${OUTPUT_NAME}_AP.tar.md5"
        
        # Adicionar hash ao final do arquivo (formato Odin)
        echo -n "$MD5_HASH  ${OUTPUT_NAME}_AP.tar.md5" >> "${OUTPUT_NAME}_AP.tar.md5"
        
        print_success "Hash MD5: $MD5_HASH"
    else
        print_warning "md5sum não encontrado, renomeando sem hash"
        mv "${OUTPUT_NAME}_AP.tar" "${OUTPUT_NAME}_AP.tar.md5"
    fi

    # Limpeza final
    print_status "Limpando arquivos temporários..."
    rm -rf extracted/ odin_package/
    
    # Remover super_raw.img apenas se foi criado (não é o original)
    if [ "$SUPER_RAW" != "$SUPER_IMG_ABS" ]; then
        rm -f super_raw.img
    fi
    
    print_success "Arquivo para Odin criado: ${OUTPUT_NAME}_AP.tar.md5"

    # Resumo final
    echo
    print_success "================================================"
    print_success "    PROCESSO CONCLUÍDO COM SUCESSO!"
    print_success "================================================"
    echo
    print_status "Arquivo gerado:"
    print_status "📦 ${OUTPUT_NAME}_AP.tar.md5 ($(ls -lh ${OUTPUT_NAME}_AP.tar.md5 | awk '{print $5}'))"
    echo
    print_warning "INSTRUÇÕES DE USO:"
    print_warning "1. ⚠️  FAÇA BACKUP COMPLETO do seu dispositivo antes do flash"
    print_warning "2. 📱 Coloque o dispositivo em modo Download (Vol Up + Power)"
    print_warning "3. 💻 Abra o Odin no computador"
    print_warning "4. 📂 Carregue o arquivo ${OUTPUT_NAME}_AP.tar.md5 na aba AP"
    print_warning "5. ✅ Verifique se Re-Partition NÃO está marcado"
    print_warning "6. 🚀 Clique em Start para iniciar o flash"
    print_warning "7. 🔄 Após o flash, considere fazer factory reset"
    echo
    print_success "✨ Sucesso! Warnings do lpmake sobre 'sparse format' são normais"
    print_success "🛡️  Arquivo validado e pronto para flash seguro!"
    print_status "📍 Local: $(pwd)/${OUTPUT_NAME}_AP.tar.md5"
    print_status "⏰ Processo concluído em: $(date)"
    echo
    print_warning "💡 DICAS FINAIS DE SEGURANÇA:"
    print_warning "• Teste primeiro em dispositivo secundário se possível"
    print_warning "• Mantenha o cabo USB bem conectado durante o flash"
    print_warning "• Não interrompa o processo de flash no Odin"
    print_warning "• Tenha o firmware stock original para recuperação"
}

# Verificar se está rodando no Termux
if [ -z "$PREFIX" ]; then
    print_warning "Este script foi desenvolvido para o Termux"
    print_warning "Algumas funcionalidades podem não funcionar corretamente"
fi

# Executar função principal
main "$@"
