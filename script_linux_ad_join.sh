#!/bin/bash
# PURPOSE:  Script utilizado para integrar computadores Linux Ubuntu ao domínio
# AUTHOR:   Gabriel Borges
# DATE:     21/09/2021

DC01=""
DC01_IP=""
DC02=""
DC02_IP=""
DOMAIN=""
LDAPSEARCHBASE=""
LDAPUSERSEARCHBASE=""
YELLOW="\e[0;33m"
GREEN="\e[0;32m"
RED="\e[0;31m"
NC="\e[0m"


function valida_root (){
    #Verifica se o script foi executado com o usuário root
    if [[ $USER != "root" ]]; then
        echo ""
        echo "O script deve ser executado como root!"
        echo "Execute o comando 'sudo su -' e tente novamente."
        echo ""
        exit 1
    fi
}

function valida_domain_controllers (){
    for ADDRESS in $DC01.$DOMAIN $DC02.$DOMAIN $DC01_IP $DC02_IP
    do
        host $ADDRESS > /dev/null
        if [[ $? -eq 0 ]]; then
            printf "[ ${GREEN}OK${NC} ] Resolução de nome do endereço $ADDRESS\n"
        else
            printf "[ ${RED}FAIL${NC} ] Resolução de nome do endereço $ADDRESS\n"
        fi
    done
}

function altera_hostname_para_fqdn (){
    echo "Verificando se o hostname está no formato FQDN..."
    
    HOSTNAME=`hostname`
    HOSTNAME_REGEX=^[DL]L-[0-9]{3}-[0-9]{4,5}\.dominio\.local$

    until [[ $HOSTNAME =~ $HOSTNAME_REGEX ]]
    do
        if [[ $HOSTNAME =~ ^[DL]L-[0-9]{3}-[0-9]{4,5}$ ]]; then
            echo "Concatenando o domínio $DOMAIN ao hostname..."
            HOSTNAME_NOVO=$HOSTNAME.$DOMAIN
            hostnamectl set-hostname $HOSTNAME_NOVO
        else
            read -p "O hostname da máquina está fora de padrão. Insira o hostname no padrão: " HOSTNAME
            HOSTNAME_NOVO=$HOSTNAME.$DOMAIN
            hostnamectl set-hostname $HOSTNAME_NOVO
            if [[ ! $HOSTNAME_NOVO =~ $HOSTNAME_REGEX ]]; then
                continue
            fi
        fi
        printf "[ ${GREEN}OK${NC} ] O hostname foi configurado no formato FQDN\n"
        echo "O computador deverá ser reiniciado."
        echo "Ao ligar, execute o script novamente para continuar a integração ao domínio."
        read -p "Pressione [Enter] para sair."
        exit
    done

    printf "[ ${GREEN}OK${NC} ] FQDN está configurado.\n"

}

function valida_comunicacao_com_domain_controllers (){
    echo "Testando comunicação com o controladores de domínio..."
    PORTS=(389 636 88 464 445 123)
    for DC in $DC01 $DC02
    do
        echo "*** $DC ***"
        for PORT in ${PORTS[*]}
        do            
            # Check UDP/NTP
            if [[ $PORT -eq 123 ]]; then
                nc -zvu $DC $PORT
                continue
            fi
            # Check TCP Protocol
            nc -zv $DC $PORT
            # Check UDP Protocol
            nc -zv $DC $PORT
        done
    done

}

function sincronizacao_horario_com_domain_controllers (){
    echo "Validando servidores NTP..."
    
    # Verifica se o serviço NTP está ativo
    NTP_ACTIVE=`timedatectl | grep "NTP service" | egrep -o "(active|inactive)"`

    if [[ $NTP_ACTIVE != "active" ]]; then
        echo "Serviço NTP se encontra desabilitado. Habilitando serviço..."
        
        if [[ $(systemctl start systemd-timesyncd) -ne 0 ]]; then
            echo "Ocorrou um erro ao habilitar serviço NTP."
            exit 1
        fi
    fi

    # Verifica se o sincronismo NTP está habilitado
    NTP_SYNC=`timedatectl | grep "System clock synchronized" | egrep -o "(yes|no)"`

    if [[ $NTP_SYNC != "yes" ]]; then
        echo "Sincronismo NTP se encontra desabilitado. Habilitando sincronismo..."
        
        if [[ $(timedatectl set-ntp true) -ne 0 ]]; then
            echo "Ocorrou um erro ao habilitar sincronismo NTP."
            exit 1
        fi
    fi    

    # Verifica se NTP server é um controlador de domínio
    NTP_SERVERS=`systemctl status systemd-timesyncd | grep -o -E "([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|Idle)"`

    echo "$NTP_SERVERS"

    if [[ ! $NTP_SERVERS =~ ($DC01_IP|Idle) ]]; then
        echo "Configurando servidor NTP em /etc/systemd/timesyncd.conf..."
        sed -i s/"^#\?NTP=.*"/"NTP=$DC01.$DOMAIN"/ /etc/systemd/timesyncd.conf
        sed -i s/"^#\?FallbackNTP=.*"/"FallbackNTP=a.ntp.br b.ntp.br c.ntp.br"/ /etc/systemd/timesyncd.conf
        systemctl restart systemd-timesyncd
        grep "NTP=" /etc/systemd/timesyncd.conf
    fi
}

instala_pacotes_sssd (){
    echo "Atualizando repositórios..."
    apt update &> /dev/null
    PACOTES=('sssd-ad' 'sssd-tools' 'realmd' 'adcli' 'sssd-dbus')
    echo "Verificando pacotes ${PACOTES[*]}..."

    for PACOTE in ${PACOTES[*]}
    do
        PAC_STATUS=`dpkg --get-selections | grep $PACOTE | head -n1 | egrep -o "install"`
        if [[ $PAC_STATUS != "install" ]]; then
            echo "Instalando pacote $PACOTE..."
            apt install $PACOTE -y
        else
            printf "[ ${YELLOW}$PACOTE${NC} ]\tjá está instalado\n"
        fi
    done
}

integra_ao_dominio (){
    echo "Descobrindo domínio com realmd..."
    realm discover $DOMAIN &> /dev/null
    if [[ $? -ne 0 ]]; then
        printf "[ ${RED}FAIL${NC} ] Não foi possível realizar a descoberta do domínio $DOMAIN\n"
        exit 1
    fi

    JOIN_STATUS=`realm discover $DOMAIN | grep "configured:" | cut -d " " -f 4`

    if [[ $JOIN_STATUS == "kerberos-member" ]]; then
        printf "[ ${GREEN}OK${NC} ] O computador já está integrado ao domínio $DOMAIN\n"
        exit 0
    fi

    if [[ $JOIN_STATUS == "no" ]]; then
        echo "Integrando o computador ao dominio $DOMAIN..."
        read -p "Insira um administrador de domínio: " DOMAIN_ADM
        realm join -v -U $DOMAIN_ADM $DOMAIN
        if [[ $? -ne 0 ]]; then
        printf "[ ${RED}FAIL${NC} ] Não foi possível realizar a descoberta do domínio $DOMAIN\n"
        exit 1
        fi
        printf "[ ${GREEN}OK${NC} ] Computador integrado ao domínio com sucesso!\n"
    fi
}

function configura_sssdconf (){
    echo "Configurando arquivo sssd.conf..."
    # Configura padrão para o diretório 'home'
    sed -i s/"^fallback_homedir =.*"/"override_homedir = \/home\/%d\/%u"/ /etc/sssd/sssd.conf
    # Usuário não tem necessidade de informar o domínio 'user@domain', mas somente 'user'
    sed -i s/"^use_fully_qualified_names = True"/"use_fully_qualified_names = False"/ /etc/sssd/sssd.conf
    # Informa o nível de busca LDAP
    echo "ldap_search_base = $LDAPSEARCHBASE" >> /etc/sssd/sssd.conf
    echo "ldap_user_search_base = $LDAPUSERSEARCHBASE" >> /etc/sssd/sssd.conf

    echo "Reiniciando serviço sssd.service..."
    systemctl restart sssd.service && echo "Concluído!" || echo "Houve um problema na reinicialização do serviço"
}

function configura_home_directory (){
    echo "Configurando pam_mkhomedir para criar diretório home de usuários após o primeiro login"

    sed -i "s/pam_mkhomedir.so/pam_mkhomedir.so umask=0027 skel=\/etc\/skel/" /etc/pam.d/common-session
    pam-auth-update --enable mkhomedir

    echo "***************************************"
}

function main (){
    valida_root
    valida_domain_controllers
    altera_hostname_para_fqdn
    valida_comunicacao_com_domain_controllers
    sincronizacao_horario_com_domain_controllers
    instala_pacotes_sssd
    integra_ao_dominio
    configura_sssdconf
    configura_home_directory
}

main
