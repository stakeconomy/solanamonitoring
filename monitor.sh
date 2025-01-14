#!/bin/bash
# set -x # uncomment to enable debug

#####    Packages required: jq, bc
#####    Solana Validator Monitoring Script v.0.14 to be used with Telegraf / Grafana / InfluxDB
#####    Fetching data from Solana validators, outputs metrics in Influx Line Protocol on stdout
#####    Created: 14 Jan 18:28 CET 2021 by Stakeconomy.com. Forked from original Zabbix nodemonitor.sh script created by Stakezone
#####    For support post your questions in the #monitoring channel in the Solana discord server

#####    CONFIG    ##################################################################################################
configDir="$HOME/.config/solana" # the directory for the config files, eg.: /home/user/.config/solana
##### optional:        #
identityPubkey=""      # identity pubkey for the validator, insert if autodiscovery fails
voteAccount=""         # vote account address for the validator, specify if there are more than one or if autodiscovery fails
additionalInfo="on"    # set to 'on' for additional general metrics like balance on your vote and identity accounts, number of validator nodes, epoch number and percentage epoch elapsed
binDir=""              # auto detection of the solana binary directory can fail or an alternative custom installation is preferred, in case insert like $HOME/solana/target/release
rpcURL=""              # default is localhost with port number autodiscovered, alternatively it can be specified like http://custom.rpc.com:port
format="SOL"           # amounts shown in 'SOL' instead of lamports
now=$(date +%s%N)      # date in influx format
timezone="UTC"            # time zone for epoch ends metric
#####  END CONFIG  ##################################################################################################

if [ -n  "$binDir" ]; then
   cli="${binDir}/solana"
else
   if [ -z $configDir ]; then echo "please configure the config directory"; exit 1; fi
   installDir="$(cat ${configDir}/install/config.yml | grep 'active_release_dir\:' | awk '{print $2}')/bin"
   if [ -n "$installDir" ]; then cli="${installDir}/solana"; else echo "please configure the cli manually or check the configDir setting"; exit 1; fi
fi

if [ -z $rpcURL ]; then
   rpcPort=$(ps aux | grep agave-validator | grep -Po "\-\-rpc\-port\s+\K[0-9]+")
   if [ -z $rpcPort ]; then echo "nodemonitor,pubkey=$identityPubkey status=4 $now"; exit 1; fi
   rpcURL="http://127.0.0.1:$rpcPort"
fi

noVoting=$(ps aux | grep agave-validator | grep -c "\-\-no\-voting")
if [ "$noVoting" -eq 0 ]; then
   if [ -z $identityPubkey ]; then identityPubkey=$($cli address --url $rpcURL); fi
   if [ -z $identityPubkey ]; then echo "auto-detection failed, please configure the identityPubkey in the script if not done"; exit 1; fi
   if [ -z $voteAccount ]; then voteAccount=$($cli validators --url $rpcURL --output json-compact | jq -r 'first (.validators[] | select(.identityPubkey == '\"$identityPubkey\"')) | .voteAccountPubkey'); fi
   if [ -z $voteAccount ]; then echo "please configure the vote account in the script or wait for availability upon starting the node"; exit 1; fi
fi

validatorBalance=$($cli balance $identityPubkey --url $rpcURL | grep -o '[0-9.]*')
validatorVoteBalance=$($cli balance $voteAccount --url $rpcURL | grep -o '[0-9.]*')
solanaPrice=$(curl -s 'GET' 'https://api.coingecko.com/api/v3/simple/price?ids=solana&vs_currencies=usd' -H 'accept: application/json' | jq -r .solana.usd)
openfiles=$(cat /proc/sys/fs/file-nr | awk '{ print $1 }')
validatorCheck=$($cli validators --url $rpcURL)

if [ $(grep -c $voteAccount <<< $validatorCheck) == 0  ]; then echo "validator not found in set"; exit 1; fi
    blockProduction=$($cli block-production --url $rpcURL --output json-compact 2>&- | grep -v Note:)
    validatorBlockProduction=$(jq -r '.leaders[] | select(.identityPubkey == '\"$identityPubkey\"')' <<<$blockProduction)
    validators=$($cli validators --url $rpcURL --output json-compact 2>&-)
    currentValidatorInfo=$(jq -r '.validators[] | select(.voteAccountPubkey == '\"$voteAccount\"')' <<<$validators)
    delinquentValidatorInfo=$(jq -r '.validators[] | select(.voteAccountPubkey == '\"$voteAccount\"' and .delinquent == true)' <<<$validators)
    if [[ ((-n "$currentValidatorInfo" || "$delinquentValidatorInfo" ))  ]] || [[ ("$validatorBlockTimeTest" -eq "1" ) ]]; then
        status=1 #status 0=validating 1=up 2=error 3=delinquent 4=stopped
        blockHeight=$(jq -r '.slot' <<<$validatorBlockTime)
        blockHeightTime=$(jq -r '.timestamp' <<<$validatorBlockTime)
        if [ -n "$blockHeightTime" ]; then blockHeightFromNow=$(expr $(date +%s) - $blockHeightTime); fi
        if [ -n "$delinquentValidatorInfo" ]; then
              status=3
              activatedStake=$(jq -r '.activatedStake' <<<$delinquentValidatorInfo)
        if [ "$format" == "SOL" ]; then activatedStake=$(echo "scale=2 ; $activatedStake / 1000000000.0" | bc); fi
              credits=$(jq -r '.credits' <<<$delinquentValidatorInfo)
              version=$(jq -r '.version' <<<$delinquentValidatorInfo | sed 's/ /-/g')
              version2=${version//./}
              commission=$(jq -r '.commission' <<<$delinquentValidatorInfo)
              logentry="rootSlot=$(jq -r '.rootSlot' <<<$delinquentValidatorInfo),lastVote=$(jq -r '.lastVote' <<<$delinquentValidatorInfo),credits=$credits,activatedStake=$activatedStake,version=$version2,commission=$commission"
        elif [ -n "$currentValidatorInfo" ]; then
              status=0
              activatedStake=$(jq -r '.activatedStake' <<<$currentValidatorInfo)
              credits=$(jq -r '.credits' <<<$currentValidatorInfo)
              version=$(jq -r '.version' <<<$currentValidatorInfo | sed 's/ /-/g')
              version2=${version//./}
              commission=$(jq -r '.commission' <<<$currentValidatorInfo)
              logentry="rootSlot=$(jq -r '.rootSlot' <<<$currentValidatorInfo),lastVote=$(jq -r '.lastVote' <<<$currentValidatorInfo)"
              leaderSlots=$(jq -r '.leaderSlots' <<<$validatorBlockProduction)
              skippedSlots=$(jq -r '.skippedSlots' <<<$validatorBlockProduction)
              totalBlocksProduced=$(jq -r '.total_slots' <<<$blockProduction)
              totalSlotsSkipped=$(jq -r '.total_slots_skipped' <<<$blockProduction)
              if [ "$format" == "SOL" ]; then activatedStake=$(echo "scale=2 ; $activatedStake / 1000000000.0" | bc); fi
              if [ -n "$leaderSlots" ]; then pctSkipped=$(echo "scale=2 ; 100 * $skippedSlots / $leaderSlots" | bc); fi
              if [ -z "$leaderSlots" ]; then leaderSlots=0 skippedSlots=0 pctSkipped=0; fi
              if [ -n "$totalBlocksProduced" ]; then
                 pctTotSkipped=$(echo "scale=2 ; 100 * $totalSlotsSkipped / $totalBlocksProduced" | bc)
                 if [ "$pctSkipped" = 0 ] || [ "$pctTotSkipped" = 0 ]; then pctSkippedDelta=0
                 else pctSkippedDelta=$(echo "scale=2 ; 100 * ($pctSkipped - $pctTotSkipped) / $pctTotSkipped" | bc); fi
              fi
              if [ -z "$pctTotSkipped" ]; then pctTotSkipped=0 pctSkippedDelta=0; fi
              totalActiveStake=$(jq -r '.totalActiveStake' <<<$validators)
              totalDelinquentStake=$(jq -r '.totalDelinquentStake' <<<$validators)
              pctTotDelinquent=$(echo "scale=2 ; 100 * $totalDelinquentStake / $totalActiveStake" | bc)
              versionActiveStake=$(jq -r '.stakeByVersion.'\"$version\"'.currentActiveStake' <<<$validators)
              stakeByVersion=$(jq -r '.stakeByVersion' <<<$validators)
              stakeByVersion=$(jq -r 'to_entries | map_values(.value + { version: .key })' <<<$stakeByVersion)
              nextVersionIndex=$(expr $(jq -r 'map(.version == '\"$version\"') | index(true)' <<<$stakeByVersion) + 1)
              stakeByVersion=$(jq '.['$nextVersionIndex':]' <<<$stakeByVersion)
              stakeNewerVersions=$(jq -s 'map(.[].currentActiveStake) | add' <<<$stakeByVersion)
              totalCurrentStake=$(jq -r '.totalCurrentStake' <<<$validators)
              pctVersionActive=$(echo "scale=2 ; 100 * $versionActiveStake / $totalCurrentStake" | bc)
              pctNewerVersions=$(echo "scale=2 ; 100 * $stakeNewerVersions / $totalCurrentStake" | bc)
              logentry="$logentry,leaderSlots=$leaderSlots,skippedSlots=$skippedSlots,pctSkipped=$pctSkipped,pctTotSkipped=$pctTotSkipped,pctSkippedDelta=$pctSkippedDelta,pctTotDelinquent=$pctTotDelinquent"
              logentry="$logentry,version=$version2,pctNewerVersions=$pctNewerVersions,commission=$commission,activatedStake=$activatedStake,credits=$credits,solanaPrice=$solanaPrice"
           else status=2; fi
        if [ "$additionalInfo" == "on" ]; then
           nodes=$($cli gossip --url $rpcURL | grep -Po "Nodes:\s+\K[0-9]+")
           epochInfo=$($cli epoch-info --url $rpcURL --output json-compact)
           epoch=$(jq -r '.epoch' <<<$epochInfo)
           tps=$(jq -r '.transactionCount' <<<$epochInfo)
           pctEpochElapsed=$(echo "scale=2 ; 100 * $(jq -r '.slotIndex' <<<$epochInfo) / $(jq -r '.slotsInEpoch' <<<$epochInfo)" | bc)
           validatorCreditsCurrent=$($cli vote-account $voteAccount --url $rpcURL | grep credits/slots | cut -d ":" -f 2 | cut -d "/" -f 1 | awk 'NR==1{print $1}')
           TIME=$($cli epoch-info --url $rpcURL | grep "Epoch Completed Time" | cut -d "(" -f 2 | awk '{print $1,$2,$3,$4}')
           VAR1=$(echo $TIME | grep -oE '[0-9]+day' | grep -o -E '[0-9]+')
           VAR2=$(echo $TIME | grep -oE '[0-9]+h'   | grep -o -E '[0-9]+')
           VAR3=$(echo $TIME | grep -oE '[0-9]+m'   | grep -o -E '[0-9]+')
           VAR4=$(echo $TIME | grep -oE '[0-9]+s'   | grep -o -E '[0-9]+')
           
           if [ -z "$VAR1" ];
           then
           VAR1=0
           fi

           if [ -z "$VAR2" ];
           then
           VAR2=0
           fi

           if [ -z "$VAR3" ];
           then
           VAR3=0
           fi

           if [ -z "$VAR4" ];
           then
           VAR4=0
           fi
           
           epochEnds=$(TZ=$timezone date -d "$VAR1 days $VAR2 hours $VAR3 minutes $VAR4 seconds" +"%m/%d/%Y %H:%M")
           epochEnds=$(( $(TZ=$timezone date -d "$epochEnds" +%s) * 1000 ))
           voteElapsed=$(echo "scale=4; $pctEpochElapsed / 100 * 432000" | bc)
           if [ "$voteElapsed" = 0 ]; then pctVote=0
           else pctVote=$(echo "scale=4; $validatorCreditsCurrent/$voteElapsed * 100" | bc); fi
           logentry="$logentry,openFiles=$openfiles,validatorBalance=$validatorBalance,validatorVoteBalance=$validatorVoteBalance,nodes=$nodes,epoch=$epoch,pctEpochElapsed=$pctEpochElapsed,validatorCreditsCurrent=$validatorCreditsCurrent,epochEnds=$epochEnds,pctVote=$pctVote,tps=$tps"
        fi
        logentry="nodemonitor,pubkey=$identityPubkey status=$status,$logentry $now"
    else
        status=2
        logentry="nodemonitor,pubkey=$identityPubkey status=$status $now"
    fi
 echo $logentry
